import unittest

import cosmetic


class CosmeticTests(unittest.TestCase):
    def test_screen_drawing_files_take_the_light_path(self):
        self.assertIsNone(cosmetic.blocking_path([
            'strius/Features/Timeline/LearningTimelineView.swift',
            'strius/Features/Timeline/TimelineParts.swift',
            'strius/Design/Theme.swift',
            'strius/Assets.xcassets/AppIcon.appiconset/Contents.json',
            'docs/testing.md',
        ]))

    def test_processing_files_need_the_full_verification(self):
        self.assertEqual(cosmetic.blocking_path(['strius/Features/Timeline/TimelineParts.swift',
                                                 'strius/Features/Timeline/TimelineStore.swift']),
                         'strius/Features/Timeline/TimelineStore.swift')
        for path in ('strius/Runtime/UsageGate.swift', 'strius.xcodeproj/project.pbxproj',
                     'striusUITests/TimelineUITests.swift', '.github/workflows/ios.yml', 'scripts/ci/cosmetic.py',
                     'strius/Resources/Prompts/base_instructions.md'):
            self.assertEqual(cosmetic.blocking_path([path]), path)

    def test_chat_onboarding_and_billing_screens_always_need_the_full_verification(self):
        for path in ('strius/Features/Chat/MessageBubble.swift', 'strius/Features/Onboarding/PaywallView.swift',
                     'strius/Features/Settings/UsageViews.swift', 'strius/Features/Workbook/WorkbookSubunitView.swift'):
            self.assertEqual(cosmetic.blocking_path([path]), path)

    def test_an_empty_diff_is_not_light(self):
        self.assertEqual(cosmetic.blocking_path(['', ' ']), '(差分なし)')


if __name__ == '__main__':
    unittest.main()
