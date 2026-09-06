import assert from 'node:assert/strict';
import {
  DEFAULT_PERSISTENT_HIGHLIGHT_SETTINGS,
  normalizePersistentHighlightSettings
} from './persistent-highlight-settings.mjs';

assert.deepEqual(normalizePersistentHighlightSettings(), DEFAULT_PERSISTENT_HIGHLIGHT_SETTINGS);
assert.deepEqual(normalizePersistentHighlightSettings({
  enabled: true,
  terms: ' Special \nspecial\nDaily check in\n',
  color: '#FF9800',
  wholeWords: true
}), {
  enabled: true,
  terms: ['Special', 'Daily check in'],
  color: '#ff9800',
  wholeWords: true
});
assert.equal(normalizePersistentHighlightSettings({ color: 'red' }).color, '#fff176');

console.log('PASS: persistent highlight settings are normalized and bounded');
