#!/usr/bin/env python3
"""Pure-function checks for Revvy's offline wake-phrase listener.

Run with: ``python3 tests/voice_listener_test.py``.  This intentionally does
not require Vosk, PipeWire, or a microphone.
"""
import importlib.util
import pathlib
import unittest


SOURCE = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "revvy-ai-voice-listener.py"
SPEC = importlib.util.spec_from_file_location("revvy_voice_listener", SOURCE)
LISTENER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LISTENER)


class VoiceListenerTests(unittest.TestCase):
    def test_default_revvy_aliases_cover_vosk_renderings(self):
        variants = LISTENER.aliases("Hey Revvy!")
        self.assertIn("hey ready", variants)
        self.assertIn("hey riley", variants)
        self.assertTrue(LISTENER.hotword_in("hey ready", variants))

    def test_calibration_profile_is_scoped_to_its_hotword(self):
        config = {
            "voiceProfiles": {
                "computer nova": {"aliases": ["computer nora"], "inputGain": 1.2},
            },
        }
        self.assertEqual(LISTENER.profile_for(config, "Computer Nova")["aliases"],
                         ["computer nora"])
        self.assertEqual(LISTENER.profile_for(config, "Hey Revvy"), {})

    def test_wake_prefix_is_not_sent_as_the_command(self):
        variants = LISTENER.aliases("Hey Revvy", ["hey ready"])
        self.assertEqual(
            LISTENER.strip_hotword_prefix("hey ready what is the weather", variants),
            "what is the weather",
        )

    def test_stricter_sensitivity_rejects_a_weak_fuzzy_match(self):
        variants = ("hey ready",)
        self.assertTrue(LISTENER.hotword_in("hey radio", variants, "1e-20"))
        self.assertFalse(LISTENER.hotword_in("hey radio", variants, "1e-40"))


if __name__ == "__main__":
    unittest.main()
