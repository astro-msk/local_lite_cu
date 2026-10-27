import asyncio
import json
import time

import pytest

from litecu.core import Engine, StaleObservation, UserInterruption, choose_target, validate_batch, validate_action


def action(name="type_text", **args):
    return {"name": name, "arguments": args or {"text": "200"}, "reason": "Enter value", "sensitive": False}


def act(*actions):
    return {"kind": "act", "confidence": 1, "actions": list(actions or [action()])}


class Driver:
    instructions = "Test driver"
    activity_generation = 0
    user_activity = 0

    def __init__(self):
        self.executed, self.snapshots, self.closed = [], 0, False
        self.fail = None

    async def snapshot(self):
        self.snapshots += 1
        return {"context": f"screen-{self.snapshots}", "summary": "Test view", "images": []}

    async def execute(self, item):
        if self.fail:
            error, self.fail = self.fail, None
            raise error
        self.executed.append(item)
        return "Dispatched"

    def close(self):
        self.closed = True


class Model:
    def __init__(self, *decisions):
        self.decisions = list(decisions)
        self.prompts = []

    async def decide(self, prompt, images, schema):
        self.prompts.append(prompt)
        if not self.decisions:
            return {"kind": "finish", "result": "Verified"}
        decision = self.decisions.pop(0)
        return await decision() if callable(decision) else decision

    def cancel(self):
        pass


def setup(model, **settings):
    desktop, arc, events = Driver(), Driver(), []
    engine = Engine(model, {"desktop": desktop, "arc": arc}, events.append, {"approval": "full", "idle_seconds": 0.01, **settings})
    return engine, desktop, arc, events


@pytest.mark.parametrize("command,target", [("Play Spotify playlist", "desktop"), ("Spotify web player", "arc"), ("Open native Spotify app", "desktop"), ("Calculate 200 in Calculator", "desktop"), ("Read example.com", "arc"), ("Open Finder", "desktop"), ("Look in my browser", "arc")])
def test_target_routing(command, target):
    assert choose_target(command)[0] == target
    assert choose_target(command, "arc")[0] == "arc"
    assert choose_target(command, "desktop")[0] == "desktop"


async def test_whole_number_is_one_action_and_verifies():
    engine, desktop, _, events = setup(Model(act(action(text="200"))))
    assert await engine.run("Calculator 200") == "Verified"
    assert len(desktop.executed) == 1 and desktop.executed[0]["arguments"]["text"] == "200"
    assert desktop.snapshots == 2
    assert events[-1]["status"] == "complete" and desktop.closed


async def test_approval_reject_never_dispatches():
    engine, desktop, _, events = setup(Model(act()), approval="every")
    def emit(event):
        events.append(event)
        if event["type"] == "approval":
            engine.respond("reject")
    engine.emit = emit
    await engine.run("Calculator")
    assert not desktop.executed
    assert events[-1]["status"] == "stopped"


async def test_clarification_is_not_skipped_in_full_access_and_reobserves():
    question = {"kind": "clarify", "question": "Which window?", "options": ["Left", "Right"]}
    engine, desktop, _, events = setup(Model(question, act()))
    def emit(event):
        events.append(event)
        if event["type"] == "question":
            engine.respond("Right")
    engine.emit = emit
    await engine.run("Select window")
    assert desktop.snapshots == 3
    assert "User clarification: Right" in engine.model.prompts[1]
    assert len(desktop.executed) == 1


async def test_physical_input_during_model_discards_proposed_click():
    engine, desktop, _, events = setup(Model())
    async def user_moves():
        desktop.activity_generation += 1
        desktop.user_activity = time.monotonic()
        return act(action("click", display_id=1, x=20, y=30))
    engine.model = Model(user_moves, {"kind": "finish", "result": "Reobserved"})
    assert await engine.run("Do something") == "Reobserved"
    assert not desktop.executed and desktop.snapshots == 2
    assert any(e.get("title") == "You have control" for e in events)


async def test_mid_batch_interruption_discards_remaining_actions():
    engine, desktop, _, events = setup(Model(act(action(text="2"), action(text="00"))))
    async def execute(item):
        desktop.executed.append(item)
        engine.pause()
        asyncio.get_running_loop().call_later(0.03, engine.resume)
        return "Entered first fragment"
    desktop.execute = execute
    await engine.run("Calculate")
    assert len(desktop.executed) == 1
    assert "Discard the rest of the group" in engine.model.prompts[1]


async def test_stale_geometry_reobserves_without_replaying():
    engine, desktop, _, events = setup(Model(act(), {"kind": "finish", "result": "Updated"}))
    desktop.fail = StaleObservation("Display disconnected")
    await engine.run("Calculate")
    assert not desktop.executed and desktop.snapshots == 2
    assert "Display disconnected" in engine.model.prompts[1]


async def test_target_switch_requires_auto_and_fresh_context():
    engine, desktop, arc, _ = setup(Model({"kind": "switch", "target": "arc", "reason": "Need website"}))
    await engine.run("Investigate this")
    assert desktop.snapshots == 1 and arc.snapshots == 1
    engine, desktop, arc, events = setup(Model({"kind": "switch", "target": "arc"}), target="desktop")
    await engine.run("Investigate")
    assert events[-1]["status"] == "failed" and arc.snapshots == 0


async def test_stop_while_waiting_for_answer_is_prompt():
    engine, desktop, _, events = setup(Model(act()), approval="every")
    def emit(event):
        events.append(event)
        if event["type"] == "approval":
            engine.stop()
    engine.emit = emit
    await asyncio.wait_for(engine.run("Calculator"), 0.5)
    assert not desktop.executed and events[-1]["status"] == "stopped"


async def test_low_confidence_asks_instead_of_clicking():
    decision = act(action("click", display_id=1, x=1, y=1))
    decision["confidence"] = 0.4
    engine, desktop, _, events = setup(Model(decision))
    def emit(event):
        events.append(event)
        if event["type"] == "question":
            engine.respond("Stop this task")
    engine.emit = emit
    await engine.run("Click target")
    assert not desktop.executed and any(e["type"] == "question" for e in events)


def test_group_rejects_navigation_and_clicks_and_focus_changes():
    for actions in ([action("click", display_id=1, x=1, y=1), action()], [action("press_key", key="cmd+l"), action()], [action("press_key", key="return"), action()]):
        with pytest.raises(ValueError):
            validate_batch(actions, "desktop")
    validate_batch([action("press_key", key="cmd+a"), action(text="200"), action("press_key", key="return")], "desktop")


@pytest.mark.parametrize("url", ["javascript:alert(1)", "https://user:password@example.com", "https://example.com/\ue200", "file:///tmp/a"])
def test_navigation_validation(url):
    with pytest.raises(ValueError):
        validate_action(action("open_url", url=url), "arc")

async def test_nullable_schema_arguments_are_removed_before_dispatch():
    engine, desktop, _, _ = setup(Model(act(action(text='200', seconds=None, button=None))))
    await engine.run('Calculator')
    assert desktop.executed[0]['arguments'] == {'text': '200'}


async def test_user_click_during_approval_requires_fresh_observation():
    engine, desktop, _, events = setup(Model(act()), approval='every')
    def accept_review():
        raise UserInterruption('User changed target during review')
    desktop.accept_review = accept_review
    def emit(event):
        events.append(event)
        if event['type'] == 'approval':
            engine.respond('approve')
    engine.emit = emit
    await engine.run('Calculator')
    assert not desktop.executed and desktop.snapshots == 2
    assert 'User changed target' in engine.model.prompts[1]

async def test_arc_observation_generation_is_not_physical_input_generation():
    engine, _, arc, events = setup(Model(), target='arc')
    async def snapshot():
        return {'context': 'Example Domain', 'summary': 'Arc', 'images': [], 'generation': 42}
    arc.snapshot = snapshot
    assert await asyncio.wait_for(engine.run('Read example.com'), 1) == 'Verified'
    assert events[-1]['status'] == 'complete'

async def test_stop_cancels_inflight_driver_call_before_cleanup():
    engine, desktop, _, events = setup(Model(act()))
    entered, cancelled = asyncio.Event(), asyncio.Event()
    async def execute(item):
        entered.set()
        try:
            await asyncio.sleep(30)
        except asyncio.CancelledError:
            cancelled.set()
            raise
    desktop.execute = execute
    run = asyncio.create_task(engine.run('Calculator'))
    await entered.wait()
    engine.stop()
    await asyncio.wait_for(run, 1)
    assert cancelled.is_set() and desktop.closed and events[-1]['status'] == 'stopped'

def test_embedded_submit_or_focus_character_ends_group():
    for value in ['200\n', '200\t', '200\r']:
        with pytest.raises(ValueError, match='submit or change focus'):
            validate_batch([action(text=value), action(text='more')], 'desktop')


@pytest.mark.parametrize("key", ["escape", "return"])
async def test_rejected_group_reobserves_then_corrects_without_approval_or_budget_use(key):
    key_action, text_action = action("press_key", key=key), action(text="200")
    model = Model(act(key_action, text_action), act(key_action), act(text_action))
    engine, desktop, _, events = setup(model, approval="every", max_steps=2)

    def emit(event):
        events.append(event)
        if event["type"] == "approval":
            engine.respond("approve")
    engine.emit = emit

    assert await engine.run("Enter 200 in Calculator") == "Verified"
    assert desktop.executed == [key_action, text_action]
    assert desktop.snapshots == 4
    assert [event["actions"] for event in events if event["type"] == "approval"] == [[key_action], [text_action]]
    assert len([node for node in engine.nodes if node["kind"] == "action"]) == 2
    context = [json.loads(prompt.rsplit("\n\n", 1)[1]) for prompt in model.prompts]
    assert [item["observation"] for item in context] == ["screen-1", "screen-2", "screen-3", "screen-4"]
    assert [item["actions_remaining"] for item in context] == [2, 2, 1, 0]
    assert "Observe after any key" in context[1]["history"][0]
    assert "No action from this group ran" in context[1]["history"][0]
    assert "Escape and Return MUST be the last action" in model.prompts[0]
    assert events[-1]["status"] == "complete" and desktop.closed


@pytest.mark.parametrize("invalid", [
    act(action("press_key", key="escape"), action(text="200")),
    {"kind": "act", "confidence": 1, "actions": "malformed"},
])
async def test_invalid_action_proposals_are_bounded_before_approval_or_execution(invalid):
    model = Model(invalid, invalid, invalid, act())
    engine, desktop, _, events = setup(model, approval="every")

    # A mistaken approval event must fail promptly, not hang the test.
    def emit(event):
        events.append(event)
        if event["type"] == "approval":
            engine.respond("approve")
    engine.emit = emit

    result = await engine.run("Enter 200 in Calculator")
    assert "three invalid action proposals" in result
    assert len(model.prompts) == 3 and desktop.snapshots == 3
    assert len(model.decisions) == 1  # No unbounded retry or dispatch of the fourth proposal.
    assert not desktop.executed
    assert not any(event["type"] == "approval" for event in events)
    assert not any(node["kind"] == "action" for node in engine.nodes)
    assert len(engine.history) == 3
    assert events[-1]["status"] == "failed" and desktop.closed
