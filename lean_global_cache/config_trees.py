"""Lean tag configuration for the shared config installer."""
from substrate.config_trees import ConfigTree, Flat
from wisp_api import owner_paths


def tag_prompts():
    return ConfigTree("lean-tag-prompts", "tags/prompts", Flat("*.txt"),
                      owner_paths.tag_prompts_dir, required=("lean.txt",),
                      required_by=("lean-global-cache",))


def tag_setup():
    return ConfigTree("lean-tag-setup", "tags/setup", Flat("*.sh", mode=0o755),
                      owner_paths.tag_setup_dir, required=("lean.sh",),
                      required_by=("lean-global-cache",))


def tag_teardown():
    return ConfigTree("lean-tag-teardown", "tags/teardown", Flat("*.sh", mode=0o755),
                      owner_paths.tag_teardown_dir, required=("lean.sh",),
                      required_by=("lean-global-cache",))
