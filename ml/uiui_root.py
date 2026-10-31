import os

ROOT = os.path.abspath(os.environ.get("UIUI_ML_ROOT") or "workspace")
os.environ["UIUI_ML_ROOT"] = ROOT


def load_yaml(path_or_text, is_text=False):
    import yaml
    text = path_or_text if is_text else open(path_or_text).read()
    return yaml.safe_load(os.path.expandvars(text))

SPEECH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "speech")
