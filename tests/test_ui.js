const test = require('node:test');
const assert = require('node:assert/strict');
const ui = require('../files/root/www/luci-static/resources/vpn-nftset.js');
const {createFixture} = require('./ui_dom_fixture');

test('client input preserves DNS overrides and rejects invalid domain or DNS values', () => {
    assert.equal(ui.normalizeEntry('Example.COM./Ns#05353').raw, 'example.com/ns#5353');
    assert.equal(ui.normalizeEntry('example.com/2001:0db8::1#5300').dns, '2001:db8::1#5300');
    for (const value of ['*.example.com', 'https://example.com', 'example.com/999.8.8.8', 'example.com/ns#65536']) {
        assert.throws(() => ui.normalizeEntry(value), undefined, value);
    }
});

test('coverage respects domain boundaries and selects the nearest custom parent', () => {
    const entries = ui.parseEntries('example.com\nsub.example.com');
    assert.deepEqual(ui.customCoverage('sub.example.com', entries), {exact: true, domain: 'sub.example.com'});
    assert.deepEqual(ui.customCoverage('deep.sub.example.com', entries), {exact: false, domain: 'sub.example.com'});
    assert.equal(ui.customCoverage('notexample.com', entries), null);
});

test('paging and search keep the full custom list, edits preserve DNS, and reset restores saved rules', async () => {
    const saved = Array.from({length: 21}, (_, i) => `host${String(i).padStart(2, '0')}.example.com`);
    saved.push('specific.example.net/ns#5353');
    const fixture = createFixture({custom: saved.join('\n')});
    await fixture.flush();
    fixture.actions['custom-next'].emit('click');
    assert.match(fixture.roles['custom-rows'].textContent, /host10.example.com/);
    assert.equal(fixture.textarea.value, saved.join('\n'));
    fixture.roles['custom-search'].value = 'NS#5353';
    fixture.roles['custom-search'].emit('input');
    assert.match(fixture.roles['custom-rows'].textContent, /specific.example.net/);
    assert.equal(fixture.actions['refresh'].disabled, false);
    fixture.roles['custom-rows'].children[0].children[2].children[0].emit('click');
    assert.equal(fixture.textarea.value, saved.slice(0, -1).join('\n'));
    assert.equal(fixture.actions['refresh'].disabled, true);
    fixture.actions['refresh'].emit('click');
    assert.equal(fixture.requests.some(request => request.url === '/refresh'), false);
    fixture.roles['custom-entry'].value = 'new.example.net/ns#5353';
    fixture.actions['add-custom'].emit('click');
    assert.equal(fixture.textarea.value, saved.slice(0, -1).concat('new.example.net/ns#5353').join('\n'));
    fixture.reset();
    fixture.runTimers(0);
    await fixture.flush();
    assert.equal(fixture.textarea.value, saved.join('\n'));
    assert.equal(fixture.actions['refresh'].disabled, false);
    fixture.roles['custom-entry'].value = 'temporary.example.org';
    fixture.actions['add-custom'].emit('click');
    fixture.roles['custom-rows'].children[0].children[2].children[0].emit('click');
    assert.equal(fixture.actions['refresh'].disabled, false);
});

test('native setting drafts block refresh until reset; list searches and filters stay usable', async () => {
    const fixture = createFixture();
    await fixture.flush();
    for (const event of ['input', 'change', 'widget-change']) {
        fixture.root.emit(event, {target: fixture.setting});
        assert.equal(fixture.actions['refresh'].disabled, true);
        fixture.reset();
        fixture.runTimers(0);
        await fixture.flush();
        assert.equal(fixture.actions['refresh'].disabled, false);
    }
    for (const [event, target] of [['input', fixture.roles['custom-search']], ['input', fixture.roles['downloaded-search']], ['change', fixture.roles['source-filter']]]) {
        fixture.root.emit(event, {target});
        assert.equal(fixture.actions['refresh'].disabled, false);
    }
});

test('Enter in either search cancels implicit saving and preserves unsaved custom rules', async () => {
    const fixture = createFixture();
    await fixture.flush();
    fixture.roles['custom-entry'].value = 'unsaved.example.net';
    fixture.actions['add-custom'].emit('click');
    await fixture.flush();
    const draft = fixture.textarea.value;
    for (const name of ['custom-search', 'downloaded-search']) {
        let prevented = false;
        fixture.roles[name].emit('keydown', {key: 'Enter', preventDefault() { prevented = true; }});
        assert.equal(prevented, true, name + ' must not submit the configuration form');
        assert.equal(fixture.textarea.value, draft);
        assert.equal(fixture.actions['refresh'].disabled, true);
    }
});

test('read-only users can browse lists while edits and late-rendered LuCI widgets remain disabled', async () => {
    const fixture = createFixture({readonly: true});
    await fixture.flush();
    assert.equal(fixture.roles['custom-entry'].disabled, true);
    assert.equal(fixture.actions['refresh'].disabled, true);
    fixture.tabs[2].emit('click');
    assert.equal(fixture.panels[2].hidden, false);
    fixture.roles['custom-search'].value = 'missing';
    fixture.roles['custom-search'].emit('input');
    assert.equal(fixture.roles['custom-rows'].textContent, 'No matching domains.');
    const controls = await fixture.hydrateSettings();
    assert.equal(controls.input.disabled, true);
    assert.equal(controls.dropdown.tabIndex, -1);
    for (const event of ['click', 'keydown']) {
        let blocked = false;
        fixture.root.emit(event, {target: controls.dropdown, preventDefault() { blocked = true; }, stopImmediatePropagation() {}});
        assert.equal(blocked, true);
    }
});

test('invalid legacy custom values remain visible and removable', async () => {
    const fixture = createFixture({custom: 'good.example\nlegacy/path/extra'});
    await fixture.flush();
    assert.match(fixture.roles['custom-rows'].textContent, /legacy/);
    assert.equal(fixture.textarea.value, 'good.example\nlegacy/path/extra');
    fixture.roles['custom-rows'].children[1].children[2].children[0].emit('click');
    assert.equal(fixture.textarea.value, 'good.example');
});

test('failed catalog requests expose retry and recover without reloading the page', async () => {
    const fixture = createFixture({outcomes: [new Error('offline')]});
    await fixture.flush();
    assert.equal(fixture.roles['notice'].hidden, false);
    assert.equal(fixture.actions['refresh'].disabled, true);
    fixture.actions['retry'].emit('click');
    await fixture.flush();
    assert.equal(fixture.roles['notice'].hidden, true);
    assert.match(fixture.roles['downloaded-rows'].textContent, /cdn.example.com/);
});

test('late overlap responses cannot overwrite feedback for a newly added domain', async () => {
    const fixture = createFixture();
    await fixture.flush();
    let finishOldCheck;
    fixture.outcomes.push(new Promise(resolve => { finishOldCheck = resolve; }), {overlap: {exact: true}});
    fixture.roles['custom-entry'].value = 'old.example.net';
    fixture.roles['custom-entry'].emit('input');
    fixture.runTimers(350);
    fixture.roles['custom-entry'].value = 'new.example.net';
    fixture.actions['add-custom'].emit('click');
    await fixture.flush();
    assert.match(fixture.roles['custom-feedback'].textContent, /Included in a downloaded list/);
    finishOldCheck({overlap: {parent: 'stale.example'}});
    await fixture.flush();
    assert.doesNotMatch(fixture.roles['custom-feedback'].textContent, /stale/);
    assert.equal(fixture.textarea.value, 'example.com\nnew.example.net');
});

test('refresh sends the CSRF token by POST and reports backend failure after polling', async () => {
    const fixture = createFixture();
    await fixture.flush();
    fixture.outcomes.push({started: true}, {...fixture.catalog, refresh_status: 'failed'});
    fixture.actions['refresh'].emit('click');
    await fixture.flush();
    const request = fixture.requests.at(-1);
    assert.equal(request.url, '/refresh');
    assert.equal(request.options.method, 'POST');
    assert.equal(request.options.body, 'token=fixture-token');
    assert.equal(fixture.actions['refresh'].disabled, true);
    fixture.runTimers(1000);
    await fixture.flush();
    assert.match(fixture.roles['notice-message'].textContent, /Update finished with errors/);
    assert.equal(fixture.actions['refresh'].disabled, false);
});
