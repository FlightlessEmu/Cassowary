import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('xcframework_library', Path(__file__).parents[1] / 'xcframework-library.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PlatformSelectionTests(unittest.TestCase):
    def test_selects_platform_and_variant_instead_of_slice_folder_name(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'framework with spaces.xcframework'
            entries = []
            expected = {}
            for index, (mode, platform, variant, static) in enumerate([
                    ('device', 'ios', None, False), ('simulator', 'ios', 'simulator', False),
                    ('catalyst', 'ios', 'maccatalyst', True), ('tvos', 'tvos', None, False),
                    ('tvos-sim', 'tvos', 'simulator', False), ('macos', 'macos', None, False)]):
                identifier = f'arbitrary-folder-{index}'
                library = 'libMoltenVK.a' if static else 'MoltenVK.framework'
                entry = {'LibraryIdentifier': identifier, 'LibraryPath': library,
                         'SupportedArchitectures': ['arm64'], 'SupportedPlatform': platform}
                if variant:
                    entry['SupportedPlatformVariant'] = variant
                entries.append(entry)
                binary = root / identifier / library
                if not static:
                    binary /= 'MoltenVK'
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b'fixture')
                expected[mode] = binary
            with (root / 'Info.plist').open('wb') as stream:
                plistlib.dump({'AvailableLibraries': list(reversed(entries))}, stream)
            for mode, binary in expected.items():
                with self.subTest(mode=mode):
                    self.assertEqual(module.select_library(root, mode), binary)

    def test_rejects_desktop_library_for_phone(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with (root / 'Info.plist').open('wb') as stream:
                plistlib.dump({'AvailableLibraries': []}, stream)
            with self.assertRaisesRegex(ValueError, 'no ARM64 device'):
                module.select_library(root, 'device')
