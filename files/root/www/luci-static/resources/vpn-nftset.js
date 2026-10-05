(function (global) {
    'use strict';

    function normalizeEntry(value) {
        const parts = value.trim().split('/');
        if (parts.length > 2 || (parts.length === 2 && !parts[1])) throw new Error('Use domain or domain/IP#port.');
        const domain = parts[0].trim().toLowerCase().replace(/\.$/, '');
        const labels = domain.split('.');
        if (domain.length > 253 || labels.length < 2 || /^\d+$/.test(labels[labels.length - 1]) ||
            labels.some(label => !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label) || label.length > 63)) {
            throw new Error('Enter a domain such as example.com.');
        }
        let dns = '';
        if (parts.length === 2) {
            const address = parts[1].trim().split('#');
            if (address.length > 2 || (address.length === 2 && (!/^\d+$/.test(address[1]) || Number(address[1]) < 1 || Number(address[1]) > 65535))) {
                throw new Error('Use an IP address or hostname for DNS, optionally followed by #port');
            }
            let host = address[0];
            if (host.includes(':')) {
                try { host = new URL('http://[' + host + ']/').hostname.slice(1, -1); }
                catch (_) { throw new Error('Use an IP address or hostname for DNS, optionally followed by #port'); }
            } else {
                const bytes = host.split('.');
                if (/^[\d.]+$/.test(host) && host.includes('.')) {
                    if (bytes.length !== 4 || bytes.some(byte => !/^\d{1,3}$/.test(byte) || Number(byte) > 255)) {
                        throw new Error('Use an IP address or hostname for DNS, optionally followed by #port');
                    }
                    host = bytes.map(Number).join('.');
                } else {
                    host = host.toLowerCase().replace(/\.$/, '');
                    const hostLabels = host.split('.');
                    if (host.length > 253 || (hostLabels.length === 1 && !/[a-z]/.test(host)) ||
                        (hostLabels.length > 1 && /^\d+$/.test(hostLabels.at(-1))) ||
                        hostLabels.some(label => !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label) || label.length > 63)) {
                        throw new Error('Use an IP address or hostname for DNS, optionally followed by #port');
                    }
                }
            }
            dns = host + (address.length === 2 ? '#' + Number(address[1]) : '');
        }
        return {domain: domain, dns: dns, raw: domain + (dns ? '/' + dns : '')};
    }

    function parseEntries(text) {
        return text.split(/\r?\n/).map(line => line.trim()).filter(Boolean).map(raw => {
            try { return normalizeEntry(raw); }
            catch (_) { return {domain: raw.split('/')[0], dns: raw.split('/')[1] || '', raw: raw, invalid: true}; }
        });
    }

    function paginate(entries, query, page, size) {
        const needle = query.trim().toLowerCase();
        const filtered = entries.filter(entry => entry.raw.toLowerCase().includes(needle))
            .slice().sort((a, b) => a.domain.localeCompare(b.domain) || a.raw.localeCompare(b.raw));
        const pages = Math.max(1, Math.ceil(filtered.length / size));
        page = Math.min(pages, Math.max(1, page));
        return {rows: filtered.slice((page - 1) * size, page * size), total: filtered.length, page: page, pages: pages, page_size: size};
    }

    function customCoverage(domain, entries) {
        const exact = entries.find(entry => entry.domain === domain);
        if (exact) return {exact: true, domain: exact.domain};
        const parents = entries.filter(entry => domain.endsWith('.' + entry.domain));
        parents.sort((a, b) => b.domain.length - a.domain.length);
        return parents.length ? {exact: false, domain: parents[0].domain} : null;
    }

    function createCustomModel(text) {
        const entries = parseEntries(text);
        return {
            entries: entries,
            add: function (value) {
                const entry = normalizeEntry(value);
                if (entries.some(existing => existing.domain === entry.domain)) return {added: false, entry: entry};
                entries.push(entry);
                return {added: true, entry: entry};
            },
            remove: function (raw) {
                const index = entries.findIndex(entry => entry.raw === raw);
                if (index !== -1) entries.splice(index, 1);
            },
            serialize: function () { return entries.map(entry => entry.raw).join('\n'); }
        };
    }

    const api = {normalizeEntry: normalizeEntry, parseEntries: parseEntries, paginate: paginate, customCoverage: customCoverage, createCustomModel: createCustomModel};
    if (typeof module !== 'undefined' && module.exports) module.exports = api;
    global.VPNNFTsetUI = api;

    function mount(root) {
        const labels = {};
        root.querySelectorAll('[data-key]').forEach(node => { labels[node.dataset.key] = node.textContent; });
        const t = key => labels[key] || key;
        const role = name => root.querySelector('[data-role="' + name + '"]');
        const action = name => root.querySelector('[data-action="' + name + '"]');
        const textarea = root.querySelector('.vpn-custom-value');
        if (!textarea) return;
        const model = createCustomModel(textarea.value);
        const readonly = root.dataset.readonly === 'true';
        const initial = model.serialize();
        let customPage = 1, downloadedPage = 1, latestRequest = 0, latestCheck = 0, queryTimer, checkTimer, pollTimer, refreshing = false, loadError = false, settingsDirty = false;
        let current = {rows: [], sources: [], counts: {downloaded: 0}, telegram: {}, enabled: false};

        function node(tag, text, className) {
            const element = document.createElement(tag);
            if (text !== undefined) element.textContent = text;
            if (className) element.className = className;
            return element;
        }

        function notice(message, error) {
            const target = role('notice');
            role('notice-message').textContent = message;
            target.classList.toggle('vpn-error', !!error);
            target.hidden = !message;
        }

        function feedback(message, error) {
            const target = role('custom-feedback');
            target.textContent = message;
            target.classList.toggle('vpn-error', !!error);
            target.hidden = !message;
        }

        function empty(body, message) {
            const row = node('tr');
            const cell = node('td', message, 'vpn-empty');
            cell.colSpan = 3;
            row.appendChild(cell);
            body.appendChild(row);
        }

        function pagination(prefix, result) {
            role(prefix + '-results').textContent = result.total.toLocaleString() + ' ' + t('domains');
            role(prefix + '-page').textContent = t('Page') + ' ' + result.page + ' / ' + result.pages;
            action(prefix + '-prev').disabled = result.page <= 1;
            action(prefix + '-next').disabled = result.page >= result.pages;
        }

        function drawCustom() {
            const result = paginate(model.entries, role('custom-search').value, customPage, 10);
            customPage = result.page;
            const body = role('custom-rows');
            body.replaceChildren();
            result.rows.forEach(entry => {
                const row = node('tr');
                if (entry.invalid) row.className = 'vpn-error';
                const domain = node('td');
                domain.appendChild(node('span', entry.domain, 'vpn-domain'));
                const ownParents = customCoverage(entry.domain, model.entries.filter(other => other !== entry));
                if (ownParents) domain.appendChild(node('small', t('Covered by') + ' ' + ownParents.domain, 'vpn-row-note'));
                row.appendChild(domain);
                row.appendChild(node('td', entry.dns || t('Default DNS'), 'vpn-dns'));
                const controls = node('td', undefined, 'vpn-action-column');
                const remove = node('button', t('Remove'), 'btn vpn-remove');
                remove.type = 'button';
                remove.disabled = readonly;
                remove.setAttribute('aria-label', t('Remove custom domain') + ' ' + entry.domain);
                remove.addEventListener('click', () => { model.remove(entry.raw); sync(); drawCustom(); drawDownloaded(); });
                controls.appendChild(remove);
                row.appendChild(controls);
                body.appendChild(row);
            });
            if (!result.rows.length) empty(body, t(model.entries.length ? 'No matching domains.' : 'No custom domains yet.'));
            pagination('custom', result);
            role('custom-count').textContent = new Set(model.entries.map(entry => entry.domain)).size.toLocaleString();
            role('custom-state').textContent = t(model.serialize() === initial ? 'Stable rules you manage' : 'Unsaved changes');
        }

        function sync() {
            textarea.value = model.serialize();
            textarea.dispatchEvent(new Event('change', {bubbles: true}));
            drawSources();
        }

        function sourceLabel(source) {
            const index = current.sources.findIndex(item => item.id === source.id);
            return t(source.kind === 'gfw' ? 'GFWList' : 'Domain list') + ' ' + (index + 1);
        }

        function sourceLink(url, text, className) {
            const link = node(/^https?:\/\//i.test(url || '') ? 'a' : 'span', text, className);
            if (link.tagName === 'A') {
                link.href = url;
                link.target = '_blank';
                link.rel = 'noopener noreferrer';
            }
            link.title = url || '';
            return link;
        }

        function drawDownloaded() {
            const body = role('downloaded-rows');
            body.replaceChildren();
            current.rows.forEach(entry => {
                const row = node('tr');
                row.appendChild(node('td', entry.domain, 'vpn-domain'));
                const sourceCell = node('td');
                (Array.isArray(entry.sources) ? entry.sources : []).forEach(source => {
                    sourceCell.appendChild(sourceLink(source.url, sourceLabel(source), 'vpn-source-tag'));
                });
                row.appendChild(sourceCell);
                const coverage = customCoverage(entry.domain, model.entries);
                row.appendChild(node('td', coverage ? (coverage.exact ? t('Custom') : t('Covered by') + ' ' + coverage.domain) : '—', coverage ? 'vpn-coverage' : 'vpn-muted'));
                body.appendChild(row);
            });
            if (!current.rows.length) empty(body, t(current.counts.downloaded ? 'No matching domains.' : 'No downloaded domains yet. Enable the rules and update subscriptions.'));
            pagination('downloaded', current);
        }

        const statusLabels = {ok: 'Up to date', cached: 'Using cached list', bundled: 'Bundled fallback', not_downloaded: 'Not downloaded', download_failed: 'Download failed', invalid_data: 'Invalid downloaded data', apply_failed: 'Could not apply rules', cache_failed: 'Rules applied; could not save cache'};
        const failed = status => /failed|invalid/.test(status || '');
        const time = epoch => epoch ? new Date(epoch * 1000).toLocaleString(document.documentElement.lang || undefined) : t('Never');

        function drawSources() {
            const body = role('source-status');
            body.replaceChildren();
            const sources = current.sources.concat([{kind: 'telegram', url: current.telegram.url, count: current.telegram.count, cached: current.telegram.cached, status: current.telegram.enabled ? current.telegram.status : 'disabled', last_success: current.telegram.last_success}]);
            sources.forEach(source => {
                const row = node('div', undefined, 'vpn-source-row');
                const name = node('div', undefined, 'vpn-source-name');
                name.appendChild(node('strong', source.kind === 'telegram' ? 'Telegram' : sourceLabel(source)));
                name.appendChild(sourceLink(source.url, source.url, 'vpn-source-url'));
                row.appendChild(name);
                const detail = node('div', undefined, 'vpn-source-detail');
                detail.appendChild(node('span', (source.count || 0).toLocaleString() + ' ' + t(source.kind === 'telegram' ? 'IP ranges' : 'domains')));
                detail.appendChild(node('small', t('Last success') + ': ' + time(source.last_success)));
                if (failed(source.status) && source.cached) detail.appendChild(node('small', t('Cached list retained'), 'vpn-cache-note'));
                else if (failed(source.status) && source.kind === 'telegram' && source.count) detail.appendChild(node('small', t('Bundled fallback'), 'vpn-cache-note'));
                row.appendChild(detail);
                row.appendChild(node('span', t(source.status === 'disabled' ? 'Disabled' : (statusLabels[source.status] || 'Not downloaded')), 'vpn-badge' + (failed(source.status) ? ' vpn-badge-error' : '')));
                body.appendChild(row);
            });
            const selected = role('source-filter').value;
            const first = role('source-filter').firstElementChild;
            role('source-filter').replaceChildren(first);
            current.sources.forEach(source => {
                const option = node('option', sourceLabel(source));
                option.value = source.id;
                role('source-filter').appendChild(option);
            });
            role('source-filter').value = selected;
            role('downloaded-count').textContent = current.counts.downloaded.toLocaleString();
            role('telegram-count').textContent = (current.telegram.count || 0).toLocaleString();
            role('telegram-state').textContent = t(current.telegram.enabled ? (statusLabels[current.telegram.status] || 'Not downloaded') : 'Disabled');
            role('schedule-state').textContent = t(current.auto_update ? 'At startup and daily 04:04' : 'Automatic updates off');
            role('service-state').textContent = t(current.running || refreshing ? 'Updating…' : (current.enabled ? 'Enabled' : 'Disabled'));
            role('service-state').classList.toggle('vpn-badge-enabled', !!current.enabled);
            const pending = current.pending_changes || settingsDirty || model.serialize() !== initial;
            action('refresh').disabled = readonly || !current.enabled || pending || current.running || refreshing;
            action('refresh').title = pending ? t('Save and apply your settings before updating.') : (current.enabled ? '' : t('Save and apply the enabled setting before updating.'));
        }

        function catalogURL(extra) {
            const parameters = new URLSearchParams({scope: 'downloaded', q: role('downloaded-search').value, page: downloadedPage, page_size: 25, source: role('source-filter').value});
            Object.keys(extra || {}).forEach(key => parameters.set(key, extra[key]));
            return root.dataset.catalogUrl + '?' + parameters.toString();
        }

        async function request(url, options) {
            const response = await fetch(url, Object.assign({credentials: 'same-origin', cache: 'no-store'}, options));
            let data;
            try { data = await response.json(); }
            catch (_) { throw new Error('request_failed'); }
            if (!response.ok) throw new Error(data.error || 'request_failed');
            return data;
        }

        async function load() {
            const serial = ++latestRequest;
            try {
                const data = await request(catalogURL());
                if (serial !== latestRequest) return;
                data.rows = Array.isArray(data.rows) ? data.rows : [];
                data.sources = Array.isArray(data.sources) ? data.sources : [];
                current = data;
                if (loadError) { notice(''); loadError = false; }
                action('retry').hidden = true;
                action('retry').disabled = false;
                downloadedPage = current.page;
                drawSources();
                drawDownloaded();
                if (current.running || refreshing) {
                    if (!current.running) {
                        refreshing = false;
                        const errors = current.refresh_status === 'failed' || current.sources.some(source => failed(source.status)) || (current.telegram.enabled && failed(current.telegram.status));
                        const message = current.refresh_status === 'cancelled' ? 'Update cancelled.' : (errors ? 'Update finished with errors. Cached lists remain available.' : 'Update complete');
                        notice(t(message), errors);
                        drawSources();
                    } else {
                        clearTimeout(pollTimer);
                        pollTimer = setTimeout(load, 1500);
                    }
                }
            } catch (_) {
                if (serial !== latestRequest) return;
                notice(t('Could not load lists. Try again.'), true);
                loadError = true;
                action('retry').hidden = false;
                action('retry').disabled = false;
                if (refreshing) {
                    clearTimeout(pollTimer);
                    pollTimer = setTimeout(load, 3000);
                }
            }
        }

        async function checkEntry(entry) {
            const serial = ++latestCheck;
            try {
                const result = await request(catalogURL({check: entry.domain, page: 1, q: ''}));
                if (serial !== latestCheck) return;
                if (role('custom-entry').value.trim() && normalizeEntry(role('custom-entry').value).domain !== entry.domain) return;
                const overlap = result.overlap || {};
                if (overlap.exact) feedback(t('Included in a downloaded list. You can keep it as a stable custom rule.'));
                else if (overlap.parent) feedback(t('Covered by') + ' ' + overlap.parent + '. ' + t('Included in a downloaded list. You can keep it as a stable custom rule.'));
                else if (overlap.subdomains) feedback(t('Contains downloaded subdomains. You can keep it as a stable custom rule.'));
            } catch (_) { /* Adding a stable custom rule does not depend on source availability. */ }
        }

        function addCustom() {
            if (readonly) return;
            latestCheck++;
            try {
                const result = model.add(role('custom-entry').value);
                if (!result.added) { feedback(t('Already in your custom list.'), true); return; }
                role('custom-entry').value = '';
                role('custom-search').value = result.entry.domain;
                customPage = 1;
                sync();
                drawCustom();
                drawDownloaded();
                feedback('');
                checkEntry(result.entry);
            } catch (err) { feedback(t(err.message), true); }
        }

        action('add-custom').addEventListener('click', addCustom);
        action('retry').addEventListener('click', () => { action('retry').disabled = true; load(); });
        role('custom-entry').addEventListener('keydown', event => { if (event.key === 'Enter') { event.preventDefault(); addCustom(); } });
        role('custom-entry').addEventListener('input', () => {
            latestCheck++;
            feedback('');
            clearTimeout(checkTimer);
            checkTimer = setTimeout(() => {
                try {
                    const entry = normalizeEntry(role('custom-entry').value);
                    const own = customCoverage(entry.domain, model.entries);
                    if (own) feedback(own.exact ? t('Already in your custom list.') : t('Covered by') + ' ' + own.domain);
                    else checkEntry(entry);
                } catch (_) { /* Validate explicitly when the user adds the entry. */ }
            }, 350);
        });
        // LuCI's hidden Save button submits the surrounding form on Enter.
        for (const name of ['custom-search', 'downloaded-search']) {
            role(name).addEventListener('keydown', event => {
                if (event.key === 'Enter' && !event.isComposing) event.preventDefault();
            });
        }
        role('custom-search').addEventListener('input', () => { customPage = 1; drawCustom(); });
        action('custom-prev').addEventListener('click', () => { customPage--; drawCustom(); });
        action('custom-next').addEventListener('click', () => { customPage++; drawCustom(); });
        role('downloaded-search').addEventListener('input', () => { clearTimeout(queryTimer); downloadedPage = 1; queryTimer = setTimeout(load, 250); });
        role('source-filter').addEventListener('change', () => { downloadedPage = 1; load(); });
        const trackSettings = event => {
            if (!readonly && event.target.closest('.cbi-value-field') && !event.target.closest('.vpn-custom-editor')) {
                settingsDirty = true;
                drawSources();
            }
        };
        for (const event of ['input', 'change', 'widget-change']) root.addEventListener(event, trackSettings);
        const form = root.closest('form');
        if (form) form.addEventListener('reset', () => {
            clearTimeout(checkTimer);
            latestCheck++;
            setTimeout(() => {
                model.entries.splice(0, model.entries.length, ...parseEntries(textarea.defaultValue));
                textarea.value = model.serialize();
                role('custom-entry').value = '';
                role('custom-search').value = '';
                customPage = 1;
                downloadedPage = 1;
                settingsDirty = false;
                feedback('');
                drawCustom();
                drawSources();
                drawDownloaded();
                load();
            }, 0);
        });
        action('downloaded-prev').addEventListener('click', () => { downloadedPage--; load(); });
        action('downloaded-next').addEventListener('click', () => { downloadedPage++; load(); });
        action('refresh').addEventListener('click', async () => {
            if (action('refresh').disabled) return;
            action('refresh').disabled = true;
            try {
                await request(root.dataset.refreshUrl, {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: new URLSearchParams({token: root.dataset.token}).toString()});
                refreshing = true;
                notice(t('Updating…'));
                drawSources();
                pollTimer = setTimeout(load, 1000);
            } catch (err) {
                const errors = {service_disabled: 'Save and apply the enabled setting before updating.', settings_not_applied: 'Save and apply your settings before updating.', update_running: 'An update is already running.', permission_denied: 'Permission denied.'};
                notice(t(errors[err.message] || 'Could not start the update.'), true);
                load();
            }
        });

        const tabs = Array.from(root.querySelectorAll('[data-tab]'));
        function selectTab(tab, focus) {
            tabs.forEach(button => { const active = button === tab; button.setAttribute('aria-selected', active); button.tabIndex = active ? 0 : -1; });
            root.querySelectorAll('[data-panel]').forEach(panel => { panel.hidden = panel.dataset.panel !== tab.dataset.tab; });
            if (focus) {
                tab.focus();
                tab.scrollIntoView({block: 'nearest', inline: 'nearest'});
            }
        }
        tabs.forEach((tab, index) => {
            tab.addEventListener('click', () => selectTab(tab));
            tab.addEventListener('keydown', event => {
                let next;
                if (event.key === 'ArrowRight') next = tabs[(index + 1) % tabs.length];
                if (event.key === 'ArrowLeft') next = tabs[(index + tabs.length - 1) % tabs.length];
                if (event.key === 'Home') next = tabs[0];
                if (event.key === 'End') next = tabs[tabs.length - 1];
                if (next) { event.preventDefault(); selectTab(next, true); }
            });
        });
        const errorPanel = root.querySelector('.cbi-value-error')?.closest('[data-panel]');
        selectTab(errorPanel ? tabs.find(tab => tab.dataset.tab === errorPanel.dataset.panel) : tabs[0]);
        textarea.hidden = true;
        root.querySelector('.vpn-custom-controls').hidden = false;
        let readonlyObserver;
        if (readonly) {
            role('custom-entry').disabled = true;
            action('add-custom').disabled = true;
            const disableSettings = () => {
                root.querySelectorAll('.cbi-value-field input, .cbi-value-field select, .cbi-value-field textarea, .cbi-value-field button, .cbi-value-field [tabindex]').forEach(control => {
                    if (!control.closest('.vpn-custom-editor')) {
                        control.disabled = true;
                        control.tabIndex = -1;
                        control.setAttribute('aria-disabled', 'true');
                    }
                });
            };
            disableSettings();
            const blockSettings = event => {
                if (event.target.closest('.cbi-value-field') && !event.target.closest('.vpn-custom-editor')) {
                    event.preventDefault();
                    event.stopImmediatePropagation();
                }
            };
            root.addEventListener('click', blockSettings, true);
            root.addEventListener('keydown', blockSettings, true);
            // LuCI replaces data-ui-widget placeholders after asynchronous rendering.
            readonlyObserver = new global.MutationObserver(records => {
                if (records.some(record => record.addedNodes.length)) disableSettings();
            });
            readonlyObserver.observe(root, {childList: true, subtree: true});
        }
        drawCustom();
        load();
        global.addEventListener('pagehide', () => {
            clearTimeout(pollTimer); clearTimeout(queryTimer); clearTimeout(checkTimer);
            readonlyObserver?.disconnect();
            latestRequest++; latestCheck++;
        });
    }

    api.mount = mount;
    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => document.querySelectorAll('.vpn-app').forEach(mount));
        else document.querySelectorAll('.vpn-app').forEach(mount);
    }
})(typeof window === 'undefined' ? globalThis : window);
