import pytest
from litecu.voice import parse_voice_command, resolve_answer


@pytest.mark.parametrize("transcript, expected", [
    ("Open Calculator. CU start.", "Open Calculator"),
    ("CU start execution, open Calculator", "open Calculator"),
    ("Open Calculator C U start", "Open Calculator"),
    ("Open Calculator. See you start execution.", "Open Calculator"),
    ("Open Calculator. see you start.", "Open Calculator"),
])
def test_final_trigger(transcript, expected):
    assert parse_voice_command(transcript) == (expected, True)


@pytest.mark.parametrize("transcript", ["CU start", "See you start execution.", "C U start."])
def test_empty_task_never_executes(transcript):
    assert parse_voice_command(transcript) == ("", False)


@pytest.mark.parametrize("transcript", ["Explain what see you start means", "Rescue starts here", "CU starter", "Open Calculator"])
def test_normal_speech_stays_reviewable(transcript):
    assert parse_voice_command(transcript) == (transcript, False)


def test_voice_answers_map_options_without_guessing_custom_text():
    options = ["Docs", "Examples"]
    assert resolve_answer("Option two.", options) == "Examples"
    assert resolve_answer("DOCS", options) == "Docs"
    assert resolve_answer("My custom answer", options) == "My custom answer"
