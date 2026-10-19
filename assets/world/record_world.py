#!/usr/bin/env python3
"""Export a synchronized world video and track audio; never capture the desktop."""
import argparse
import configparser
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def load_view(config_path, name):
    allowed = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-'
    if not name or len(name) > 40 or any(char not in allowed for char in name):
        raise ValueError('View names must be 1–40 letters, digits, underscores or hyphens')
    config = configparser.ConfigParser(interpolation=None)
    config.read(config_path)
    section = 'world_view_' + name
    if section not in config:
        raise ValueError(f'No saved view {name!r}. Open forte-world --view {name}, frame the shot, then press V.')
    pose = [float(config[section][key]) for key in ('x', 'y', 'z', 'yaw', 'pitch')]
    x, y, z, yaw, pitch = pose
    valid = all(map(math.isfinite, pose)) and abs(x) <= 52 and abs(z) <= 52
    valid &= 0.1 <= y <= 20 and abs(yaw) <= math.pi and abs(pitch) <= math.pi * .42
    if not valid:
        raise ValueError('Saved viewpoint is invalid or outside the world bounds')
    dimensions = config.getint(section, 'width', fallback=1280), config.getint(section, 'height', fallback=720)
    return pose, dimensions


def resolve_output(track, requested):
    output = Path(requested).expanduser().absolute() if requested else Path.cwd() / 'recordings' / (track.stem + '.mp4')
    if not requested:
        suffix = 2
        while output.exists():
            output = output.with_name(f'{track.stem}-{suffix}.mp4')
            suffix += 1
    if output.exists():
        raise ValueError(f'Output already exists: {output}; choose --output (nothing is overwritten)')
    output.parent.mkdir(parents=True, exist_ok=True)
    return output


def resolve_settings(args):
    if not shutil.which('ffmpeg'):
        raise ValueError('FFmpeg is required on PATH')
    track = Path(args.track).expanduser().resolve(strict=True)
    if not track.is_file():
        raise ValueError('Track must be a regular file')
    pose, saved_size = load_view(args.config, args.view)
    if (args.width is None) != (args.height is None):
        raise ValueError('Specify both --width and --height, or neither to preserve saved framing')
    width, height = (args.width, args.height) if args.width is not None else tuple(value - value % 2 for value in saved_size)
    if width % 2 or height % 2 or not 480 <= width <= 3840 or not 320 <= height <= 2160:
        raise ValueError('Use even dimensions between 480x320 and 3840x2160')
    return track, pose, width, height, resolve_output(track, args.output)


def decode_audio(track, work):
    wav, pcm = work / 'audio.wav', work / 'mono.f32'
    subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(track), '-map', '0:a:0', '-vn', '-ar', '44100', '-ac', '2', '-c:a', 'pcm_s16le', str(wav)], check=True)
    subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(wav), '-ac', '1', '-ar', '44100', '-f', 'f32le', str(pcm)], check=True)
    pcm_size = pcm.stat().st_size
    if pcm_size == 0 or pcm_size % 4:
        raise ValueError('Decoded track has no complete audio samples')
    return wav, pcm, pcm_size // 4, pcm_size / 4 / 44100


def start_pipeline(args, pcm, wav, partial, pose, width, height):
    dimensions = f'{width}x{height}'
    renderer = subprocess.Popen(
        [args.renderer, '--render-recording', str(pcm), str(width), str(height), str(args.fps), *map(str, pose)],
        stdout=subprocess.PIPE,
    )
    try:
        encoder = subprocess.Popen(
            ['ffmpeg', '-nostdin', '-v', 'warning', '-y', '-f', 'rawvideo', '-pixel_format', 'rgba',
             '-video_size', dimensions, '-framerate', str(args.fps), '-i', 'pipe:0', '-i', str(wav),
             '-map', '0:v:0', '-map', '1:a:0', '-vf', 'vflip', '-c:v', 'libx264', '-preset', 'medium',
             '-crf', '18', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart', partial],
            stdin=renderer.stdout,
        )
    except BaseException:
        stop(renderer)
        raise
    renderer.stdout.close()
    return renderer, encoder


def stop(child):
    if child is None or child.poll() is not None:
        return
    child.terminate()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()


def publish(partial, output):
    # Atomic, same-filesystem, and race-safe: never replace an existing export.
    os.link(partial, output)
    os.unlink(partial)


def record(args):
    track, pose, width, height, output = resolve_settings(args)
    partial = renderer = encoder = None
    try:
        with tempfile.TemporaryDirectory(prefix='forte-record-') as directory:
            print(f'Decoding {track.name}…', file=sys.stderr)
            wav, pcm, _, duration = decode_audio(track, Path(directory))
            descriptor, partial = tempfile.mkstemp(prefix='.' + output.stem + '-', suffix='.partial.mp4', dir=output.parent)
            os.close(descriptor)
            print(f'Recording {duration:.2f}s, {width}x{height} at {args.fps} fps from view {args.view!r}. Esc cancels.', file=sys.stderr)
            renderer, encoder = start_pipeline(args, pcm, wav, partial, pose, width, height)
            if renderer.wait() != 0:
                raise ValueError('World rendering failed or was cancelled; no final video was published')
            if encoder.wait() != 0:
                raise ValueError('FFmpeg encoding failed; no final video was published')
            publish(partial, output)
            partial = None
            print(f'Saved {output}', file=sys.stderr)
    finally:
        stop(renderer)
        stop(encoder)
        if renderer is not None and renderer.stdout is not None:
            renderer.stdout.close()
        if partial is not None:
            Path(partial).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('track')
    parser.add_argument('--view', default='saved')
    parser.add_argument('--output')
    parser.add_argument('--width', type=int)
    parser.add_argument('--height', type=int)
    parser.add_argument('--fps', type=int, choices=(30, 60), default=60)
    parser.add_argument('--renderer', required=True)
    parser.add_argument('--config', required=True)
    try:
        record(parser.parse_args())
    except KeyboardInterrupt:
        print('Recording cancelled; no final video published', file=sys.stderr)
        return 130
    except (ValueError, OSError, KeyError, configparser.Error, subprocess.CalledProcessError) as error:
        print(f'Recording failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
