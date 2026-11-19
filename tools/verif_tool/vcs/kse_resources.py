"""Resource gate for strict-final VCS jobs. Never changes the shell environment."""
from pathlib import Path
import os
import subprocess

REPO = Path(__file__).resolve().parents[3]

def e203_sources():
    local = REPO / 'third-party/e203'
    if not (local / 'rtl/e203').is_dir():
        local = REPO.parent / 'project/third-party/e203'
    expected = subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD:third-party/e203'], text=True).strip()
    actual = subprocess.check_output(['git', '-C', str(local), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != expected:
        raise ValueError('E203 checkout does not match pinned gitlink')
    # Record actual file hashes too: revision alone does not establish file identity.
    return local / 'rtl/e203'

def guarded_execute(execute, argv, cwd, name, seconds):
    # The shared wrapper owns queueing, memory admission, and the 10G scope.
    # Keep this adapter so all existing runners use the same policy without
    # embedding a second lock or MemAvailable threshold.
    wrapper = os.environ.get('VCS_SLOT_WRAPPER')
    if wrapper and Path(argv[0]).name in ('vcs', 'simv', 'urg'):
        argv = [wrapper] + argv
    return execute(argv, cwd, name, seconds)

def memory_config(repo):
    """Return optional technology SRAM metadata, defaulting to public models."""
    cfg = os.environ.get('KSE_PDK_CONFIG')
    if cfg and Path(cfg).is_file():
        import yaml
        p = Path(cfg)
        return p, yaml.safe_load(p.read_text())['memories']
    names = ['RAMSP128X16', 'RAMSP1024X16', 'RAMSP4096X16']
    return Path(repo / 'tb/models'), {'names': names, 'v': str(repo / 'tb/models/{name}_beh.sv'), 'sim_defines': [], 'sim_opts': []}
