const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const model = {module: {exports: {}}};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../packages/nier-onedrive/sources/Model.js'), 'utf8'), model);
const {parseJsonl, eventSnapshot} = model.module.exports;
const record = (event, sequence = 1) => ({schemaVersion: 1, sequence, event});
assert.equal(parseJsonl('{broken\n' + JSON.stringify(record({state: 'ready'})) + '\n{"partial').length, 1);
let events = [record({type: 'transfer', path: '__proto__', progress: 50, state: 'syncing'})];
assert.equal(eventSnapshot(events).transfers[0].path, '__proto__');
events.push(record({type: 'sync-complete', state: 'completed'}, 2));
assert.equal(eventSnapshot(events).transfers.length, 0);
events = [record({type: 'error', detail: '<b>failed</b>'}), record({state: 'completed'})];
assert.equal(eventSnapshot(events).lastError, '');
events = [record({type: 'transfer', path: 'file.txt', progress: 50}), record({type: 'transfer', path: 'file.txt', complete: true}, 2)];
assert.equal(eventSnapshot(events).transfers.length, 0);
console.log('OneDrive model checks passed');
const {isConnected} = model.module.exports;
for (const state of ['ready', 'syncing', 'processing', 'completed', 'completed-with-errors', 'action-required']) {
    assert.equal(isConnected('active', 'success', state), true, state);
}
for (const state of ['', 'initializing', 'connecting', 'offline', 'authentication-required', 'error']) {
    assert.equal(isConnected('active', 'success', state), false, state);
}
assert.equal(isConnected('inactive', 'success', 'completed'), false);
assert.equal(isConnected('failed', 'exit-code', 'syncing'), false);
assert.equal(isConnected('active', 'exit-code', 'ready'), false);
