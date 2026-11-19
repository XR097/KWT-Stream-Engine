# KWT-1 量化环境

本项目的量化模型阶段使用独立的 Conda 环境。官方 KWT 代码基于 TensorFlow 2.4，当前默认采用 CPU 作为可复现基线。

## 目录约定

默认把数据和生成物放在仓库内的 `kwt-data`：

```text
kwt-data/
  data2/       # Speech Commands V2 解压目录
  cache/       # 校准缓存
  golden/      # 逐层 golden 数据
  reports/     # 精度和环境报告
```

数据目录默认被 Git 忽略。需要放到其他磁盘时，可以设置 `KWT_DATA_ROOT`，或在命令行传入 `--data-root` / `-DataRoot`。

建议为压缩包、解压数据、环境缓存和 golden 结果预留 20--30 GiB。

## 创建环境

在 PowerShell 中执行：

```powershell
conda env create -f quantization\environment\kwt-quant-environment.yml
conda activate kwt-quant
```

如果 Conda 环境文件不可用，也可以使用：

```powershell
conda create -n kwt-quant python=3.8.18 pip
conda activate kwt-quant
python -m pip install -r quantization\environment\requirements-kwt-quant.txt
```

TensorFlow 2.4 的 GPU 依赖需要旧版 CUDA/cuDNN。量化阶段不安装 CUDA 11，也不修改现有 CUDA/PyTorch 环境；CPU 运行是默认路径。

## 数据目录初始化和检查

初始化目录（不会安装软件；首次运行量化入口时会自动下载并校验数据集）：

```powershell
.\quantization\scripts\setup_kwt_quant.ps1 -DataRoot kwt-data
```

检查环境、checkpoint、数据集和磁盘空间：

```powershell
.\quantization\scripts\check_kwt_quant_env.ps1 -DataRoot kwt-data
```

脚本会报告 Python、TensorFlow、TensorFlow Addons、NumPy 版本，KWT-1 checkpoint 是否存在，以及 `data2` 是否已经准备好。

## 验收标准

环境可用需要同时满足：

1. Python 为 3.8.x，TensorFlow 为 2.4.0，NumPy 为 1.19.5；
2. `tensorflow_addons`、`scipy`、`matplotlib` 和 `pytest` 可以导入（这些是当前环境文件声明的运行时/工具依赖）；
3. KWT-1 checkpoint 能从 `third-party/kwt/models_data_v2_12_labels/kwt1` 读取；
4. `data2` 指向 Speech Commands V2 解压目录；
5. 数据根目录建议至少有 20 GiB 可用空间；准备脚本在低于 10 GiB 时会停止，避免中断下载或生成物；
6. 基线验证使用 CPU，GPU 设备可以为空。

如果 Windows 下无法获取 TensorFlow 2.4.0 的 Python 3.8 wheel，再考虑 WSL2/Linux 的独立环境；不要为了绕过安装问题升级项目的 TensorFlow 版本。

## Linux x86_64（推荐）

原生 x86_64 Linux 可直接使用原 requirements，TensorFlow 2.4.0 wheel 需要 CPU 支持 AVX。
已在 x86_64 Ubuntu 24.04 上验证（2026-11-02）：

```sh
# Miniconda 非交互安装到 ~/miniconda3，不修改 shell 配置
conda create -y -n kwt-quant python=3.8.18 pip --override-channels -c conda-forge
conda run --no-capture-output -n kwt-quant python -m pip install -r quantization/environment/requirements-kwt-quant.txt
git submodule update --init third-party/kwt   # checkpoint 位于该子模块
conda run --no-capture-output -n kwt-quant python -B -c 'from quantization.data import prepare_dataset; print(prepare_dataset("kwt-data"))'
conda run --no-capture-output -n kwt-quant python -B quantization/scripts/check_kwt_quant_env.py
```

使用 conda-forge 可避开 defaults 频道的服务条款交互提示。实测 Python 3.8.18、TensorFlow 2.4.0、
TensorFlow Addons 0.12.1、NumPy 1.19.5、SciPy 1.5.4、Matplotlib 3.3.4、pytest 7.4.4，`pip check` 无冲突；
TensorFlow 关于缺少 `libcudart.so.11.0` 的提示在 CPU 运行时可忽略。`python -B -m pytest quantization/tests -q`
全部通过。全测试集实测精度见 [ASIC 数值实验报告](asic_numerics_report.md)。

构造 AudioProcessor 时对 TensorFlow gfile.Glob 的结果排序，否则枚举顺序不确定，每次抽到的 unknown 样本不同。
`baseline`/`calibrate` 按 32 条一批编码并流式统计各层 trace 的 max / p99.99，结果与整批计算逐位相同；
此前一次性保留 4890 条 × 180 个 trace（超过 33 GB），普通机器会内存不足。

## macOS arm64 / Rosetta

如果当前环境没有 TensorFlow 2.4.0 的 arm64 wheel，不升级项目依赖。使用 Rosetta
和 `CONDA_SUBDIR=osx-64` 创建 Python 3.8.18 的 `kwt-quant`，并在该环境
固定 `subdir: osx-64`，再安装原 requirements。Rosetta 不支持 AVX，TensorFlow 导入时 SIGABRT，
因此 macOS 上只能运行不导入 TensorFlow 的整数验证、来源识别与 golden 导出；
完整测试请使用上面的 Linux x86_64 环境。
