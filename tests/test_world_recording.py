"""Run with: PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p test_world_recording.py"""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('record_world', Path(__file__).parents[1] / 'assets/world/record_world.py')
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)


class RecordingTests(unittest.TestCase):
    def test_view_and_dimensions(self):
        with tempfile.TemporaryDirectory() as directory:
            ini = Path(directory) / 'config.ini'
            ini.write_text('[world_view_shot]\nx=2\ny=1.8\nz=8\nyaw=0.3\npitch=-0.2\nwidth=1120\nheight=720\n')
            pose, size = recorder.load_view(ini, 'shot')
            self.assertEqual(pose, [2, 1.8, 8, .3, -.2])
            self.assertEqual(size, (1120, 720))
            for name in ('missing', '../bad', ''):
                with self.assertRaises(ValueError):
                    recorder.load_view(ini, name)
            ini.write_text('[world_view_shot]\nx=nan\ny=1.8\nz=8\nyaw=0\npitch=0\n')
            with self.assertRaises(ValueError):
                recorder.load_view(ini, 'shot')

    def test_stop_escalates_and_reaps(self):
        class Child:
            def __init__(self):
                self.terminated = self.killed = False
                self.waits = 0
            def poll(self):
                return None
            def terminate(self):
                self.terminated = True
            def kill(self):
                self.killed = True
            def wait(self, timeout=None):
                self.waits += 1
                if timeout is not None:
                    raise recorder.subprocess.TimeoutExpired('test', timeout)
                return 0
        child = Child()
        recorder.stop(child)
        self.assertTrue(child.terminated and child.killed)
        self.assertEqual(child.waits, 2)

    def test_failed_decode_leaves_no_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            track, ini, output = root / 'track.flac', root / 'config.ini', root / 'out.mp4'
            track.write_bytes(b'invalid')
            ini.write_text('[world_view_saved]\nx=0\ny=1.8\nz=11\nyaw=0\npitch=0\n')
            args = recorder.argparse.Namespace(track=str(track), config=str(ini), view='saved', width=640, height=360, fps=30, output=str(output), renderer='unused')
            with patch.object(recorder.shutil, 'which', return_value='/fake/ffmpeg'), patch.object(recorder.subprocess, 'run', side_effect=recorder.subprocess.CalledProcessError(1, 'ffmpeg')):
                with self.assertRaises(recorder.subprocess.CalledProcessError):
                    recorder.record(args)
            self.assertFalse(output.exists())
            self.assertFalse(list(root.glob('*.partial.mp4')))


if __name__ == '__main__':
    unittest.main()
