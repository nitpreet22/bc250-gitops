"""Tests for scripts/agent-notify's decisions: which status changes push, what the push says, and
the flood limits. Run with Python 3.10+ (bc250-2, or `py` on the PC):

    python3 -m unittest tests/test_agent_notify.py
"""

import importlib.machinery
import importlib.util
import unittest
from pathlib import Path

_path = Path(__file__).resolve().parent.parent / "scripts/agent-notify"
_loader = importlib.machinery.SourceFileLoader("agent_notify", str(_path))
_spec = importlib.util.spec_from_loader("agent_notify", _loader)
an = importlib.util.module_from_spec(_spec)
_loader.exec_module(an)


def status_event(terminal, state, msg=None):
    status = {"app": "claude-code", "state": state}
    if msg:
        status["msg"] = msg
    return {"method": "event", "params": {"terminal": terminal, "type": "status",
                                          "data": {"status": status, "reported": True}}}


def snapshot(*terminals):
    return {"seq": 1, "terminals": list(terminals)}


NIGHTLY = {"address": "t12", "name": "nightly", "title": "✳ Nightly data report",
         "labels": {"hl.tab": "nightly", "where": "nightly / 1"}, "status": {"state": "idle"}}


class PushKind(unittest.TestCase):
    def test_blocked_needs_you_whatever_came_before(self):
        for previous in (None, "idle", "working", "done"):
            self.assertEqual(an.push_kind(previous, "blocked"), "needs_you", previous)

    def test_done_after_work_is_finished(self):
        self.assertEqual(an.push_kind("working", "done"), "finished")

    def test_done_without_work_or_idle_is_not_news(self):
        for previous, state in ((None, "done"), ("idle", "done"), ("working", "idle"),
                                (None, "idle"), ("blocked", "blocked"), ("idle", "working")):
            self.assertIsNone(an.push_kind(previous, state), (previous, state))

    def test_error_once(self):
        self.assertEqual(an.push_kind("working", "error"), "error")
        self.assertIsNone(an.push_kind("error", "error"))


class Naming(unittest.TestCase):
    def test_hl_project_first(self):
        self.assertEqual(an.agent_name(NIGHTLY), "nightly")

    def test_herdr_space_from_where_label(self):
        self.assertEqual(an.agent_name({"address": "t2", "labels": {"where": "3ds repair / 1"}}), "3ds repair")

    def test_address_last(self):
        self.assertEqual(an.agent_name({"address": "t9", "labels": {}}), "t9")

    def test_task_title_drops_the_spinner(self):
        self.assertEqual(an.task_title({"title": "◐ Backup drive migration"}),
                         "Backup drive migration")


class Message(unittest.TestCase):
    def test_needs_you_names_project_task_question_and_machine(self):
        push = an.build_push("needs_you", NIGHTLY, {"msg": "Which banner colour?"}, "bc250-2")
        self.assertEqual(push.title, "nightly needs you")
        self.assertEqual(push.message.splitlines(), [
            "Nightly data report", "Which banner colour?",
            "on bc250-2 · answer in the Herdr app"])
        self.assertEqual((push.priority, push.tags), (5, ("warning",)))

    def test_generic_title_is_left_out(self):
        push = an.build_push("finished", dict(NIGHTLY, title="✳ Claude Code"), {}, "bc250-2")
        self.assertEqual(push.message, "on bc250-2 · answer in the Herdr app")


class WatcherFlow(unittest.TestCase):
    def test_snapshot_never_pushes_then_changes_do(self):
        watcher = an.Watcher("bc250-2")
        blocked_in_snapshot = dict(NIGHTLY, status={"state": "blocked"})
        self.assertEqual(watcher.handle(snapshot(blocked_in_snapshot), 0), [])
        self.assertEqual(watcher.handle(status_event("t12", "working"), 1), [])
        pushes = watcher.handle(status_event("t12", "done"), 2)
        self.assertEqual([p.title for p in pushes], ["nightly finished"])

    def test_title_and_label_events_update_the_message(self):
        watcher = an.Watcher("bc250-2")
        watcher.handle(snapshot(), 0)
        watcher.handle({"params": {"terminal": "t3", "type": "labels",
                                   "data": {"labels": {"where": "3ds repair / 1"}}}}, 1)
        watcher.handle({"params": {"terminal": "t3", "type": "title",
                                   "data": {"title": "✳ New 3DS XL boot.firm"}}}, 2)
        pushes = watcher.handle(status_event("t3", "blocked", "Format the SD card?"), 3)
        self.assertEqual(pushes[0].title, "3ds repair needs you")
        self.assertIn("New 3DS XL boot.firm", pushes[0].message)

    def test_same_push_within_the_window_is_dropped(self):
        watcher = an.Watcher("bc250-2")
        watcher.handle(snapshot(NIGHTLY), 0)
        self.assertEqual(len(watcher.handle(status_event("t12", "blocked"), 10)), 1)
        watcher.handle(status_event("t12", "working"), 20)
        self.assertEqual(watcher.handle(status_event("t12", "blocked"), 30), [])
        watcher.handle(status_event("t12", "working"), 200)
        self.assertEqual(len(watcher.handle(status_event("t12", "blocked"), 10 + an.REPEAT_WINDOW_S + 1)), 1)

    def test_other_machines_terminals_are_left_to_their_own_watcher(self):
        watcher = an.Watcher("desktop-1")
        remote = dict(NIGHTLY, address="bc250-2/t12")
        watcher.handle(snapshot(remote), 0)
        watcher.handle(status_event("bc250-2/t12", "working"), 1)
        self.assertEqual(watcher.handle(status_event("bc250-2/t12", "blocked"), 2), [])
        self.assertEqual(watcher.handle(status_event("bc250-2/t12", "done"), 3), [])

    def test_burst_is_capped_per_minute(self):
        watcher = an.Watcher("bc250-2")
        terminals = [dict(NIGHTLY, address=f"t{i}", labels={"hl.tab": f"p{i}"}) for i in range(20)]
        watcher.handle(snapshot(*terminals), 0)
        pushed = sum(len(watcher.handle(status_event(f"t{i}", "blocked"), 1 + i * 0.1)) for i in range(20))
        self.assertEqual(pushed, an.MAX_PER_MINUTE)


if __name__ == "__main__":
    unittest.main()
