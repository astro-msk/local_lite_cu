"""No screen capture, permission prompts, or input events occur in these tests."""
import asyncio
import math
import os
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from litecu.geometry import ActivityTracker, DisplayGeometry, topology
from litecu.desktop import DesktopDriver, _Window, parse_key, unicode_chunks
from litecu.core import RunStopped, StaleObservation, UserInterruption


def display(display_id=1, **changes):
    values = dict(display_id=display_id,x=0,y=0,width=1440,height=900,image_width=1440,image_height=900,pixel_width=2880,pixel_height=1800)
    values.update(changes)
    return DisplayGeometry(**values)


def test_each_screen_maps_its_own_scale_and_negative_origin():
    retina = display(image_width=1600,image_height=1000)
    left = display(2,x=-1920,y=-180,width=1920,height=1080,image_width=1280,image_height=720,pixel_width=1920,pixel_height=1080)
    above = display(3,x=240,y=-1200,width=1600,height=1200,image_width=800,image_height=600)
    assert retina.point(800,500) == (720,450)
    assert left.point(640,360) == (-960,360)
    assert above.point(400,300) == (1040,-600)


def test_straddled_window_has_no_single_display_containment_requirement():
    # Left half of a window is on screen 2; right half is on screen 1.
    left = display(2,x=-1440)
    right = display(1)
    assert left.point(1400,200) == (-40,200)
    assert right.point(40,200) == (40,200)


@pytest.mark.parametrize("x,y",[(-1,0),(1440,0),(0,900),(math.inf,0),(0,math.nan),(True,10),("1",10)])
def test_outside_or_nonfinite_coordinates_rejected(x,y):
    with pytest.raises(ValueError):
        display().point(x,y)


def test_topology_order_independent_but_scale_position_and_disconnect_invalidate():
    first,second = display(),display(2,x=-1440)
    assert topology([first,second]) == topology([second,first])
    assert topology([first,second]) != topology([first])
    assert topology([first]) != topology([display(x=-10)])
    assert topology([first]) != topology([display(pixel_width=1440,pixel_height=900)])
    with pytest.raises(ValueError):
        topology([first,first])


def test_activity_does_not_store_or_count_own_synthetic_input():
    clock = Mock(return_value=12.5)
    tracker = ActivityTracker(987,clock)
    assert not tracker.record(987)
    assert tracker.state == (0,0)
    assert tracker.record(0,meaningful=False)
    assert tracker.state == (12.5,1)
    assert tracker.interaction_generation == 0
    assert tracker.record(2)
    assert tracker.interaction_generation == 1
    assert tracker.changed(1)


def prepared_driver(monkeypatch):
    driver = DesktopDriver()
    monkeypatch.setattr(driver._monitor,"assert_running",lambda:None)
    driver._pid = 123
    driver._window = None
    driver._generation,driver._interaction_generation = driver._activity.review_state
    driver._topology = ("original",)
    monkeypatch.setattr(driver,"_current_topology",lambda:("original",))
    monkeypatch.setattr(driver,"_front",lambda:SimpleNamespace(processIdentifier=lambda:123))
    monkeypatch.setattr(driver,"_focused_window",lambda pid:None)
    return driver


def test_new_human_activity_invalidates_stale_model_action(monkeypatch):
    driver = prepared_driver(monkeypatch)
    driver._activity.record(0)
    with pytest.raises(UserInterruption):
        driver._validate()


def test_changed_monitor_or_foreground_blocks_dispatch(monkeypatch):
    driver = prepared_driver(monkeypatch)
    monkeypatch.setattr(driver,"_current_topology",lambda:("new display",))
    with pytest.raises(StaleObservation,match="display"):
        driver._validate()
    monkeypatch.setattr(driver,"_current_topology",lambda:("original",))
    monkeypatch.setattr(driver,"_front",lambda:SimpleNamespace(processIdentifier=lambda:999))
    with pytest.raises(StaleObservation,match="foreground"):
        driver._validate()


def test_changed_window_blocks_dispatch(monkeypatch):
    driver = prepared_driver(monkeypatch)
    monkeypatch.setattr(driver,"_focused_window",lambda pid:_Window(object(),(1,2,3,4),"Changed"))
    with pytest.raises(StaleObservation,match="window"):
        driver._validate()


def test_approval_may_forgive_pointer_travel_but_not_target_manipulation(monkeypatch):
    driver = prepared_driver(monkeypatch)
    driver._activity.record(0,meaningful=False)
    driver.accept_review()
    driver._validate()
    driver._activity.record(0,meaningful=True)
    with pytest.raises(UserInterruption,match="review"):
        driver.accept_review()


def test_keyboard_requires_focused_window(monkeypatch):
    driver = prepared_driver(monkeypatch)
    with pytest.raises(StaleObservation,match="focused window"):
        driver._validate(require_window=True)


def test_global_stop_handler_blocks_further_input(monkeypatch):
    driver = prepared_driver(monkeypatch)
    callback = Mock()
    driver.set_stop_handler(callback)
    driver._monitor.stop_handler()
    callback.assert_called_once()
    with pytest.raises(RunStopped):
        driver._validate()


def test_unknown_display_is_rejected_before_coordinate_transform(monkeypatch):
    driver = prepared_driver(monkeypatch)
    driver._displays = {2:display(2,x=-1440)}
    monkeypatch.setattr(driver,"_check_overlay",lambda point:None)
    assert driver._point({"display_id":2,"x":100,"y":20}) == (-1340,20)
    for bad in (None,1,True,2.5):
        with pytest.raises(ValueError,match="display_id"):
            driver._point({"display_id":bad,"x":100,"y":20})


def test_shortcuts_and_whole_numbers_are_one_input_action():
    assert parse_key("cmd+k") == (40,1<<20)
    assert parse_key("command+n") == (45,1<<20)
    assert parse_key("cmd+shift+escape") == (53,(1<<20)|(1<<17))
    assert parse_key("2") == (19,0)
    assert list(unicode_chunks("200")) == [("200",3)]
    with pytest.raises(ValueError):
        parse_key("shell+rm")


def test_unicode_chunks_never_split_emoji_surrogate_pair():
    text = "a"*19+"😀"+"ö"
    chunks = list(unicode_chunks(text))
    assert chunks == [("a"*19,19),("😀ö",3)]
    assert "".join(chunk for chunk,_ in chunks) == text


def test_driver_construction_has_no_permission_or_macos_side_effects(monkeypatch):
    monkeypatch.setattr("litecu.desktop._mac",Mock(side_effect=AssertionError("Mac API called")))
    driver = DesktopDriver()
    assert driver.activity_generation == 0
    assert driver.user_activity == 0
    assert driver._directory is None


def test_hud_occlusion_rejects_click_but_does_not_block_underlying_background_ui(monkeypatch):
    driver = DesktopDriver()
    Q = SimpleNamespace(kCGWindowListOptionOnScreenOnly=1,kCGWindowListExcludeDesktopElements=2,
        kCGNullWindowID=0,kCGWindowBounds="bounds",kCGWindowAlpha="alpha",kCGWindowOwnerPID="pid")
    hud = {"bounds":{"X":100,"Y":100,"Width":200,"Height":100},"pid":os.getpid()}
    other = {"bounds":{"X":0,"Y":0,"Width":1000,"Height":1000},"pid":123}
    Q.CGWindowListCopyWindowInfo = lambda *args:[hud,other]
    monkeypatch.setattr("litecu.desktop._mac",lambda:(None,None,None,Q,None))
    with pytest.raises(StaleObservation,match="panel"):
        driver._check_overlay((150,150))
    driver._check_overlay((50,50))
    Q.CGWindowListCopyWindowInfo = lambda *args:[other,hud]
    driver._check_overlay((150,150))


def test_long_text_checks_interruption_between_chunks_without_posting_more(monkeypatch):
    driver = prepared_driver(monkeypatch)
    driver._window = _Window(object(),(0,0,100,100),"")
    monkeypatch.setattr(driver,"_validate",lambda **kwargs:None)
    monkeypatch.setattr(driver,"_restore_after_review",lambda:asyncio.sleep(0))
    monkeypatch.setattr(driver,"permissions",lambda:{"accessibility":True})
    monkeypatch.setattr(driver,"_event_source",lambda:object())
    Q = SimpleNamespace(CGEventCreateKeyboardEvent=lambda *args:object(),CGEventKeyboardSetUnicodeString=lambda *args:None)
    monkeypatch.setattr("litecu.desktop._mac",lambda:(None,None,None,Q,None))
    calls=[]
    def post_pair(*args):
        calls.append(args)
        if len(calls)==2:
            raise UserInterruption("physical input")
    monkeypatch.setattr(driver,"_post_pair",post_pair)
    with pytest.raises(UserInterruption):
        asyncio.run(driver.execute({"name":"type_text","arguments":{"text":"x"*100}}))
    assert len(calls)==2


def test_calculator_whole_value_is_fast_local_keys_in_one_execute(monkeypatch):
    driver = prepared_driver(monkeypatch)
    driver._bundle_id = "com.apple.calculator"
    monkeypatch.setattr(driver,"_validate",lambda **kwargs:None)
    monkeypatch.setattr(driver,"_restore_after_review",lambda:asyncio.sleep(0))
    monkeypatch.setattr(driver,"permissions",lambda:{"accessibility":True})
    monkeypatch.setattr(driver,"_event_source",lambda:object())
    characters=[]
    Q = SimpleNamespace(CGEventCreateKeyboardEvent=lambda source,key,down:{"down":down},
        CGEventKeyboardSetUnicodeString=lambda event,length,text:characters.append(text) if event["down"] else None)
    monkeypatch.setattr("litecu.desktop._mac",lambda:(None,None,None,Q,None))
    monkeypatch.setattr(driver,"_post_pair",lambda *args:None)
    result = asyncio.run(driver.execute({"name":"type_text","arguments":{"text":"200"}}))
    assert characters == ["2","0","0"]
    assert result == "Typed 3 characters."


def test_stop_button_blocks_in_progress_driver_input(monkeypatch):
    driver = prepared_driver(monkeypatch)
    driver.request_stop()
    with pytest.raises(RunStopped):
        driver._validate()


def test_review_ui_activity_pauses_planning_but_can_be_accepted(monkeypatch):
    driver = prepared_driver(monkeypatch)
    original_generation = driver.activity_generation
    # Same classification used for events dispatched to our own UI.
    driver._activity.record(0,meaningful=False)
    assert driver.activity_generation != original_generation
    with pytest.raises(UserInterruption):
        driver._validate()
    driver.accept_review()
    driver._validate()


def launched_app(pid=456, activate=None):
    return SimpleNamespace(processIdentifier=lambda:pid,isTerminated=lambda:False,
                           activateWithOptions_=activate or Mock(return_value=True))


def test_open_waits_until_foreground_window_is_ready(monkeypatch):
    driver = prepared_driver(monkeypatch)
    app = launched_app()
    monkeypatch.setattr(driver,"_front",lambda:app)
    reads=[]
    ready = _Window(object(),(10,10,300,400),"Calculator")
    def window(pid):
        reads.append(pid)
        return ready if len(reads)>=2 else None
    monkeypatch.setattr(driver,"_focused_window",window)
    asyncio.run(driver._wait_for_opened_app(app,"com.apple.calculator",driver.activity_generation,timeout=.5))
    assert reads == [456,456]
    assert driver._pid == 456
    assert driver._bundle_id == "com.apple.calculator"
    assert driver._window is None
    app.activateWithOptions_.assert_not_called()


def test_open_retries_activation_once_then_verifies_window(monkeypatch):
    driver = prepared_driver(monkeypatch)
    front = [SimpleNamespace(processIdentifier=lambda:123)]
    app = launched_app()
    app.activateWithOptions_ = Mock(side_effect=lambda options:front.__setitem__(0,app))
    monkeypatch.setattr(driver,"_front",lambda:front[0])
    monkeypatch.setattr(driver,"_focused_window",lambda pid:_Window(object(),(0,0,200,300),"Calculator"))
    monkeypatch.setattr("litecu.desktop._mac",lambda:(SimpleNamespace(NSApplicationActivateIgnoringOtherApps=2),None,None,None,None))
    asyncio.run(driver._wait_for_opened_app(app,"com.apple.calculator",driver.activity_generation,timeout=.6))
    app.activateWithOptions_.assert_called_once_with(2)
    assert driver._pid == 456


def test_open_never_reactivates_after_human_input(monkeypatch):
    driver = prepared_driver(monkeypatch)
    generation = driver.activity_generation
    driver._activity.record(0)
    app = launched_app()
    with pytest.raises(UserInterruption,match="took control"):
        asyncio.run(driver._wait_for_opened_app(app,"com.apple.calculator",generation,timeout=.1))
    app.activateWithOptions_.assert_not_called()


def test_open_aborts_when_human_input_arrives_during_window_wait(monkeypatch):
    driver = prepared_driver(monkeypatch)
    app = launched_app()
    monkeypatch.setattr(driver,"_front",lambda:app)
    def window(pid):
        driver._activity.record(0)
        return _Window(object(),(0,0,200,300),"Calculator")
    monkeypatch.setattr(driver,"_focused_window",window)
    with pytest.raises(UserInterruption):
        asyncio.run(driver._wait_for_opened_app(app,"com.apple.calculator",driver.activity_generation,timeout=.1))
    app.activateWithOptions_.assert_not_called()


def test_open_window_wait_is_bounded_and_does_not_claim_success(monkeypatch):
    driver = prepared_driver(monkeypatch)
    app = launched_app()
    monkeypatch.setattr(driver,"_front",lambda:app)
    monkeypatch.setattr(driver,"_focused_window",lambda pid:None)
    with pytest.raises(StaleObservation,match="not ready"):
        asyncio.run(driver._wait_for_opened_app(app,"com.apple.calculator",driver.activity_generation,timeout=.02))
    app.activateWithOptions_.assert_not_called()


def test_open_wait_honors_stop_and_display_change(monkeypatch):
    driver = prepared_driver(monkeypatch)
    app = launched_app()
    driver.request_stop()
    with pytest.raises(RunStopped):
        asyncio.run(driver._wait_for_opened_app(app,"com.apple.calculator",driver.activity_generation))
    driver._emergency_stop.clear()
    monkeypatch.setattr(driver,"_current_topology",lambda:("different",))
    with pytest.raises(StaleObservation,match="display"):
        asyncio.run(driver._wait_for_opened_app(app,"com.apple.calculator",driver.activity_generation))
    app.activateWithOptions_.assert_not_called()


def test_open_execute_invalidates_old_coordinates_even_if_launch_wait_interrupted(monkeypatch):
    driver = prepared_driver(monkeypatch)
    monkeypatch.setattr(driver,"_restore_after_review",lambda:asyncio.sleep(0))
    monkeypatch.setattr(driver,"permissions",lambda:{"accessibility":True})
    workspace = SimpleNamespace(URLForApplicationWithBundleIdentifier_=lambda bundle:object())
    config = SimpleNamespace(setActivates_=Mock())
    A = SimpleNamespace(NSWorkspace=SimpleNamespace(sharedWorkspace=lambda:workspace),
        NSWorkspaceOpenConfiguration=SimpleNamespace(configuration=lambda:config))
    monkeypatch.setattr("litecu.desktop._mac",lambda:(A,None,None,None,None))
    async def completion(invoke): return launched_app()
    async def interrupted(*args): raise UserInterruption("user interrupted launch")
    monkeypatch.setattr(driver,"_callback_result",completion)
    monkeypatch.setattr(driver,"_wait_for_opened_app",interrupted)
    with pytest.raises(UserInterruption):
        asyncio.run(driver.execute({"name":"open_app","arguments":{"bundle_id":"com.apple.calculator"}}))
    assert driver._generation is None
