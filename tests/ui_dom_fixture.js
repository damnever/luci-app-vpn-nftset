const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// This fixture supplies only the DOM, HTTP and scheduler capabilities consumed by
// the application. Tests call the real mount function and registered event handlers.
class Element {
    constructor(tag = 'div') {
        this.tagName = tag.toUpperCase();
        this.children = [];
        this.dataset = {};
        this.listeners = {};
        this.value = '';
        this.defaultValue = '';
        this.hidden = false;
        this.disabled = false;
        this._text = '';
        this.classList = {toggle() {}};
    }
    set textContent(value) { this._text = String(value); this.children = []; }
    get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
    get firstElementChild() { return this.children[0]; }
    appendChild(child) { child.parent = this; this.children.push(child); return child; }
    replaceChildren(...children) { this.children = []; this._text = ''; children.filter(Boolean).forEach(child => this.appendChild(child)); }
    setAttribute() {}
    addEventListener(name, callback) { (this.listeners[name] ||= []).push(callback); }
    dispatchEvent(event) { this.emit(event.type, event); }
    emit(name, extra = {}) { for (const callback of this.listeners[name] || []) callback({target: this, preventDefault() {}, ...extra}); }
    closest(selector) {
        if (selector === 'form') return this.tagName === 'FORM' ? this : this.parent?.closest(selector);
        if (selector === '.vpn-custom-editor') return this.customEditor ? this : this.parent?.closest(selector);
        if (selector === '.cbi-value-field') return this.valueField ? this : this.parent?.closest(selector);
        return null;
    }
}

function createFixture({readonly = false, custom = 'example.com', outcomes = []} = {}) {
    const roles = {};
    for (const name of ['service-state', 'notice', 'notice-message', 'custom-count', 'custom-state', 'downloaded-count', 'telegram-count', 'telegram-state', 'custom-entry', 'custom-feedback', 'custom-search', 'custom-results', 'custom-rows', 'custom-page', 'downloaded-search', 'source-filter', 'downloaded-results', 'downloaded-rows', 'downloaded-page', 'source-status', 'schedule-state']) roles[name] = new Element();
    roles['source-filter'].appendChild(new Element('option'));
    const actions = {};
    for (const name of ['refresh', 'retry', 'add-custom', 'custom-prev', 'custom-next', 'downloaded-prev', 'downloaded-next']) actions[name] = new Element('button');
    actions.refresh.disabled = true;
    const textarea = new Element('textarea');
    textarea.value = textarea.defaultValue = custom;
    const controls = new Element();
    const form = new Element('form');
    const root = form.appendChild(new Element());
    const editor = root.appendChild(new Element());
    editor.customEditor = true;
    editor.valueField = true;
    editor.appendChild(textarea);
    editor.appendChild(roles['custom-entry']);
    editor.appendChild(roles['custom-search']);
    const settingsField = root.appendChild(new Element());
    settingsField.valueField = true;
    const setting = settingsField.appendChild(new Element('input'));
    const settingControls = [setting];
    root.dataset = {catalogUrl: '/catalog', refreshUrl: '/refresh', token: 'fixture-token', readonly: String(readonly)};
    const tabs = ['domains', 'routing', 'subscriptions', 'advanced'].map(name => { const tab = new Element('button'); tab.dataset.tab = name; return tab; });
    const panels = tabs.map(tab => { const panel = new Element('section'); panel.dataset.panel = tab.dataset.tab; return panel; });
    root.querySelector = selector => {
        const role = selector.match(/^\[data-role="([^\"]+)"\]$/);
        const action = selector.match(/^\[data-action="([^\"]+)"\]$/);
        if (role) return roles[role[1]];
        if (action) return actions[action[1]];
        if (selector === '.vpn-custom-value') return textarea;
        if (selector === '.vpn-custom-controls') return controls;
        return null;
    };
    root.querySelectorAll = selector => {
        if (selector === '[data-tab]') return tabs;
        if (selector === '[data-panel]') return panels;
        if (selector.startsWith('.cbi-value-field')) return [...settingControls, textarea, roles['custom-entry'], roles['custom-search']];
        return [];
    };
    const source = {id: '0123456789abcdef0123456789abcdef', url: 'https://example.com/list', kind: 'gfw', count: 1, cached: true, status: 'ok'};
    const catalog = {rows: [{domain: 'cdn.example.com', sources: [source], custom: false}], sources: [source], counts: {custom: 1, downloaded: 1, total: 2}, telegram: {url: 'https://core.telegram.org/resources/cidr.txt', enabled: true, count: 14, status: 'ok', cached: true}, enabled: true, pending_changes: false, auto_update: true, running: false, refresh_status: 'ok', total: 1, page: 1, pages: 1, page_size: 25};
    const requests = [], timers = new Map(), observers = [];
    let nextTimer = 0;
    const sandbox = {
        URL, URLSearchParams,
        Event: class { constructor(type) { this.type = type; } },
        document: {readyState: 'loading', documentElement: {lang: 'en'}, addEventListener() {}, createElement: tag => new Element(tag)},
        window: {
            addEventListener() {},
            MutationObserver: class {
                constructor(callback) { this.callback = callback; observers.push(this); }
                observe(target, options) { this.target = target; this.options = options; this.active = true; }
                disconnect() { this.active = false; }
            }
        },
        setTimeout: (callback, delay) => { const id = ++nextTimer; timers.set(id, {callback, delay}); return id; },
        clearTimeout: id => timers.delete(id),
        fetch: async (url, options) => {
            requests.push({url, options});
            const outcome = await outcomes.shift();
            if (outcome instanceof Error) throw outcome;
            return {ok: true, json: async () => outcome || catalog};
        }
    };
    const code = fs.readFileSync(path.join(__dirname, '../files/root/www/luci-static/resources/vpn-nftset.js'), 'utf8');
    vm.runInNewContext(code, sandbox, {filename: 'vpn-nftset.js'});
    sandbox.window.VPNNFTsetUI.mount(root);
    return {
        root, roles, actions, textarea, tabs, panels, setting, requests, catalog, outcomes,
        async hydrateSettings() {
            // CBI resolves each widget render and replaces its placeholder in a promise.
            const markup = new Element();
            const input = markup.appendChild(new Element('input'));
            const dropdown = markup.appendChild(new Element());
            dropdown.tabIndex = 0;
            await Promise.resolve();
            settingsField.appendChild(markup);
            settingControls.push(input, dropdown);
            for (const observer of observers) {
                if (observer.active && observer.target === root && observer.options.childList && observer.options.subtree) {
                    observer.callback([{addedNodes: [markup]}]);
                }
            }
            return {input, dropdown};
        },
        runTimers(delay) {
            for (const [id, timer] of [...timers]) if (timer.delay === delay) { timers.delete(id); timer.callback(); }
        },
        reset() { form.emit('reset'); textarea.value = textarea.defaultValue; },
        flush: () => new Promise(setImmediate)
    };
}

module.exports = {createFixture};
