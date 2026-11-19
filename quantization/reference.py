"""Frozen upstream KWT-1 and an independently executable FP32 encoder.

TensorFlow is imported lazily: export consumers need only NumPy and SciPy.
Weights use Keras' ``[input, output]`` dense layout throughout.
"""

import ast
import copy
import os
from pathlib import Path
from types import SimpleNamespace
import sys

import numpy as np
from scipy.special import erf


def _read_flags(path):
    tree = ast.parse(Path(path).read_text(encoding="utf-8"), mode="eval").body
    if not isinstance(tree, ast.Call) or not isinstance(tree.func, ast.Name) or tree.func.id != "Namespace":
        raise ValueError("Expected the upstream Namespace flag snapshot")
    values = {item.arg: ast.literal_eval(item.value) for item in tree.keywords}
    values.update(distill_teacher_json="", prenorm=False, approximate_gelu=False,
                  batch_size=None, training=False, train=0, return_softmax=0,
                  use_spec_augment=0, use_spec_cutout=0, data_url="",
                  pick_deterministically=1)
    return SimpleNamespace(**values)


class _SortedGfile:
    """``gfile`` proxy whose ``Glob`` is sorted.

    TensorFlow's ``gfile.Glob`` returns matches in a nondeterministic order,
    even between two calls in one process.  Upstream AudioProcessor shuffles
    that list with a fixed seed, so without sorting every construction picks
    a different set of unknown-word samples.
    """

    def __init__(self, base):
        self._base = base

    def Glob(self, pattern):  # noqa: N802 - mirrors the upstream API name
        return sorted(self._base.Glob(pattern))

    def __getattr__(self, name):
        return getattr(self._base, name)


def _norm(x, gamma, beta):
    mean = np.mean(x, axis=-1, keepdims=True, dtype=np.float32)
    variance = np.mean(np.square(x - mean), axis=-1, keepdims=True, dtype=np.float32)
    # TensorFlow LayerNormalization computes x * inv + (beta - mean * inv).
    inv = (np.float32(1) / np.sqrt(variance + np.float32(1e-6))) * gamma
    return x * inv + (beta - mean * inv)


def forward_float(weights, boundary, trace=False, quantizer=None):
    """Independent post-norm, single-head KWT-1 encoder.

    A diagnostic quantizer can replace each weight, bias, parameter or activation
    with its dequantized approximation. Such runs are explicitly mixed precision.
    """
    traces = {}

    def parameter(name, kind="weight"):
        value = np.asarray(weights[name], dtype=np.float32)
        return value if quantizer is None else np.asarray(quantizer(name, value, kind=kind), dtype=np.float32)

    def record(name, value):
        value = np.asarray(value, dtype=np.float32)
        if quantizer is not None:
            value = np.asarray(quantizer(name, value, kind="activation"), dtype=np.float32)
        if trace:
            traces[name] = value.copy()
        return value

    def dense(name, value):
        result = np.matmul(value, parameter(name + ".weight"))
        if name + ".bias" in weights:
            result = result + parameter(name + ".bias", "bias")
        return result

    x = np.asarray(boundary, dtype=np.float32)
    if x.ndim != 3 or x.shape[1:] != (99, 64):
        raise ValueError("Encoder boundary must have shape [batch,99,64]")
    for i in range(12):
        prefix = "b%02d." % i
        x = record(prefix + "input", x)
        query = record(prefix + "q", dense(prefix + "q", x))
        key = record(prefix + "k", dense(prefix + "k", x))
        value = record(prefix + "v", dense(prefix + "v", x))
        score = record(prefix + "score", np.matmul(query, np.swapaxes(key, -1, -2)) / np.float32(8))
        exponential = np.exp(score - np.max(score, axis=-1, keepdims=True))
        softmax = record(prefix + "softmax", exponential / np.sum(exponential, axis=-1, keepdims=True))
        context = record(prefix + "context", np.matmul(softmax, value))
        projection = record(prefix + "proj", dense(prefix + "proj", context))
        residual = record(prefix + "res1", x + projection)
        normalized = record(prefix + "ln1", _norm(residual, parameter(prefix + "ln1.gamma", "parameter"), parameter(prefix + "ln1.beta", "parameter")))
        hidden = record(prefix + "fc1", dense(prefix + "fc1", normalized))
        activated = record(prefix + "gelu", np.float32(0.5) * hidden * (np.float32(1) + erf(hidden / np.float32(np.sqrt(2)))))
        hidden2 = record(prefix + "fc2", dense(prefix + "fc2", activated))
        residual2 = record(prefix + "res2", normalized + hidden2)
        x = record(prefix + "output", _norm(residual2, parameter(prefix + "ln2.gamma", "parameter"), parameter(prefix + "ln2.beta", "parameter")))
    return (x, traces) if trace else x


def classify_float(weights, encoded):
    """FP32 official class-token head, also usable by standalone exports."""
    return np.asarray(encoded, dtype=np.float32)[:, 0, :] @ weights["head.weight"] + weights["head.bias"]


class Reference:
    """One graph/session holding the restored model and all reusable probes."""

    def __init__(self, repo_root):
        os.environ["CUDA_VISIBLE_DEVICES"] = "-1"
        self.repo_root = Path(repo_root).resolve()
        upstream = self.repo_root / "third-party" / "kwt"
        sys.path.insert(0, str(upstream))
        # AudioProcessor deliberately disables eager execution in the upstream.
        from kws_streaming.data import input_data
        import tensorflow as tf
        # Import the package registry rather than kws_transformer directly.
        # kws_transformer imports models.utils, which imports the registry back.
        from kws_streaming.models import models as kws_models, model_flags
        self.tf = tf
        self.input_data = input_data
        self.checkpoint = upstream / "models_data_v2_12_labels" / "kwt1" / "best_weights"
        self.flags = model_flags.update_flags(_read_flags(self.checkpoint.parent / "flags.txt"))
        self.flags.train_dir = str(self.checkpoint.parent)
        self.graph = tf.Graph()
        threads = int(os.environ.get("KWT_TF_THREADS", "4"))
        config = tf.compat.v1.ConfigProto(device_count={"GPU": 0},
                                         intra_op_parallelism_threads=threads,
                                         inter_op_parallelism_threads=1)
        self.session = tf.compat.v1.Session(graph=self.graph, config=config)
        with self.graph.as_default(), self.session.as_default():
            tf.compat.v1.set_random_seed(59185)
            tf.compat.v1.keras.backend.set_session(self.session)
            tf.keras.backend.set_learning_phase(0)
            self.model = kws_models.MODELS["kws_transformer"](self.flags)
            if self.model.count_params() != 607308:
                raise AssertionError("Unexpected KWT-1 parameter count: %d" % self.model.count_params())
            self.transformer = next(layer for layer in self.model.layers if hasattr(layer, "enc_layers"))
            self.head = self.model.layers[-1]
            self.mfcc_tensor = next(layer.output for layer in self.model.layers if layer.__class__.__name__ == "SpeechFeatures")
            self._build_probes()
            self.session.run(tf.compat.v1.global_variables_initializer())
            status = self.model.load_weights(str(self.checkpoint))
            # Checkpoint contains optimizer bookkeeping as well as model weights.
            # Every existing model object must match before allowing extras.
            status.assert_existing_objects_matched()
            status.run_restore_ops(self.session)
            status.expect_partial()
            self.restoration = {"all_model_objects_matched": True,
                                "checkpoint_extras_allowed": True,
                                "parameter_count": self.model.count_params(),
                                "tensorflow_version": tf.__version__}
            self._weights = self._extract_weights()

    def _build_probes(self):
        tf = self.tf
        transformer = self.transformer
        projected = transformer.patch_proj(self.mfcc_tensor)
        cls = tf.broadcast_to(transformer.class_emb, [tf.shape(projected)[0], 1, 64])
        self.boundary_tensor = tf.concat([cls, projected], axis=1) + transformer.pos_emb
        if self.mfcc_tensor.shape.as_list()[1:] != [98, 40]:
            raise AssertionError("Official MFCC shape differs from [98,40]")
        self.boundary_placeholder = tf.compat.v1.placeholder(tf.float32, [None, 99, 64], name="quant_encoder_input")
        self.encoded_placeholder = tf.compat.v1.placeholder(tf.float32, [None, 99, 64], name="quant_encoder_output")
        self.head_tensor = self.head(self.encoded_placeholder[:, 0], training=False)
        self.trace_tensors = {}
        x = self.boundary_placeholder
        for i, block in enumerate(transformer.enc_layers):
            p = "b%02d." % i
            query, key, value = (block.att.query_dense(x), block.att.key_dense(x), block.att.value_dense(x))
            score = tf.matmul(query, key, transpose_b=True) / tf.constant(8., tf.float32)
            softmax = tf.nn.softmax(score, axis=-1)
            context = tf.matmul(softmax, value)
            projection = block.att.combine_heads(context)
            residual1 = x + projection
            ln1 = block.layernorm1(residual1)
            fc1 = block.ffn.layers[0](ln1)
            gelu = block.ffn.layers[1](fc1)
            fc2 = block.ffn.layers[2](gelu)
            residual2 = ln1 + fc2
            # The authoritative output calls the upstream block itself.
            output, _ = block(x, training=False)
            values = (x, query, key, value, score, softmax, context, projection,
                      residual1, ln1, fc1, gelu, fc2, residual2, output)
            names = ("input", "q", "k", "v", "score", "softmax", "context", "proj",
                     "res1", "ln1", "fc1", "gelu", "fc2", "res2", "output")
            self.trace_tensors.update({p + name: val for name, val in zip(names, values)})
            x = output
        self.encoded_tensor = x

    def _extract_weights(self):
        def read(variable):
            return self.session.run(variable).astype(np.float32)
        result = {}
        for i, block in enumerate(self.transformer.enc_layers):
            p = "b%02d." % i
            for name, layer in (("q", block.att.query_dense), ("k", block.att.key_dense),
                                ("v", block.att.value_dense), ("proj", block.att.combine_heads),
                                ("fc1", block.ffn.layers[0]), ("fc2", block.ffn.layers[2])):
                result[p + name + ".weight"] = read(layer.kernel)
                if layer.use_bias:
                    result[p + name + ".bias"] = read(layer.bias)
            for name, layer in (("ln1", block.layernorm1), ("ln2", block.layernorm2)):
                result[p + name + ".gamma"] = read(layer.gamma)
                result[p + name + ".beta"] = read(layer.beta)
        result["frontend.patch.weight"] = read(self.transformer.patch_proj.kernel)
        result["frontend.patch.bias"] = read(self.transformer.patch_proj.bias)
        result["frontend.class_emb"] = read(self.transformer.class_emb)
        result["frontend.pos_emb"] = read(self.transformer.pos_emb)
        result["head.weight"] = read(self.head.layers[0].kernel)
        result["head.bias"] = read(self.head.layers[0].bias)
        return result

    def weights(self):
        return {name: value.copy() for name, value in self._weights.items()}

    def boundary_and_logits(self, waveforms):
        boundary, logits = self.session.run(
            [self.boundary_tensor, self.model.outputs[0]],
            {self.model.inputs[0]: np.asarray(waveforms, dtype=np.float32)})
        return boundary, logits

    def mfcc(self, waveforms):
        return self.session.run(self.mfcc_tensor, {self.model.inputs[0]: np.asarray(waveforms, dtype=np.float32)})

    def encode(self, boundary, trace=False):
        feed = {self.boundary_placeholder: np.asarray(boundary, dtype=np.float32)}
        if trace:
            return tuple(self.session.run([self.encoded_tensor, self.trace_tensors], feed))
        return self.session.run(self.encoded_tensor, feed)

    def classify(self, encoded):
        return self.session.run(self.head_tensor, {self.encoded_placeholder: np.asarray(encoded, dtype=np.float32)})

    def build_processor(self, data_dir):
        flags = copy.copy(self.flags)
        flags.data_dir = str(data_dir)
        original_gfile = self.input_data.gfile
        self.input_data.gfile = _SortedGfile(original_gfile)
        try:
            with self.graph.as_default(), self.session.as_default():
                processor = self.input_data.AudioProcessor(flags)
        finally:
            self.input_data.gfile = original_gfile
        with self.graph.as_default(), self.session.as_default():
            variables = self.tf.compat.v1.global_variables()
            ready = self.session.run([self.tf.compat.v1.is_variable_initialized(v) for v in variables])
            uninitialized = [v for v, initialized in zip(variables, ready) if not initialized]
            if uninitialized:
                self.session.run(self.tf.compat.v1.variables_initializer(uninitialized))
        processor.quant_flags = flags
        return processor

    def get_batch(self, processor, mode, offset, count):
        # Upstream training mode still samples background offsets even at zero
        # volume. Disable its background list while reading calibration audio.
        background = processor.background_data
        try:
            processor.background_data = []
            with self.graph.as_default(), self.session.as_default():
                data, labels = processor.get_data(count, offset, processor.quant_flags,
                                                  0., 0., 0, mode, 0., 0., self.session)
        finally:
            processor.background_data = background
        return data.astype(np.float32), labels.astype(np.int64)

    def close(self):
        self.session.close()


def load_reference(repo_root):
    return Reference(repo_root)
