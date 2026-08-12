// ==UserScript==
// @name         Zalo Listing Bot — Web Bridge
// @namespace    zalo-listing-bot
// @version      3.0.0
// @description  2-window Zalo Web: Harvest DOM engine + Publish compose bridge
// @match        https://chat.zalo.me/*
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @connect      zdn.vn
// @connect      zaloapp.com
// @connect      zalo.me
// @run-at       document-idle
// ==/UserScript==

(function () {
    'use strict';

    const BRIDGE = {
        host: '127.0.0.1',
        port: 8080,
        pollMs: 400,
        role: 'unknown'
    };

    const SELECTORS = {
        messagePane: [
            '#messageView',
            '[class*="message-list"]',
            '[class*="chatView"]',
            '[class*="chat-content"]',
            'main [class*="scroll"]'
        ],
        messageItemTiers: [
            '[data-id="chat-item"]',
            '[data-id*="msg"]',
            'div[id^="msg-"]',
            '[role="listitem"]',
            '[class*="message-item"]',
            '[class*="msg-item"]',
            '.chat-item',
            '[class*="chat-message"]'
        ],
        messageText: [
            'span[data-translate-inner="TEXT"]',
            '[class*="text-content"]',
            '[class*="message-text"]',
            '[class*="text-message"]'
        ],
        messageImage: 'img[src*="blob:"], img[src*="zdn.vn"], img[src*="zalo"], img[class*="image"], img[class*="photo"]',
        composeBox: [
            'div[contenteditable="true"][role="textbox"]',
            '[class*="chat-input"] [contenteditable="true"]',
            'div[contenteditable="true"]',
            'textarea[class*="input"]'
        ],
        sidebarSearch: [
            'input[placeholder*="Tìm"]',
            'input[placeholder*="tim"]',
            'input[type="search"]',
            '[class*="search"] input'
        ],
        conversationTitle: [
            '[class*="header-title"]',
            '[class*="conv-title"]',
            '[class*="chat-header"] [class*="title"]',
            'header h1',
            'header [class*="name"]'
        ],
        sidebarItem: [
            '[class*="conv-item"]',
            '[class*="conversation-item"]',
            '[class*="chat-item"]',
            '[role="listitem"]'
        ],
        unreadBadge: [
            '[class*="badge"]',
            '[class*="unread"]',
            '[class*="count"]'
        ],
        excludeRegions: [
            '[class*="sidebar"]',
            '[class*="search"]',
            'header',
            '[class*="chat-input"]',
            '[class*="compose"]'
        ]
    };

    let lastPushHash = '';
    let observer = null;
    let pollTimer = null;
    let registerTimer = null;
    let observerDebounce = null;
    let pollBusy = false;
    let lastDomDiagnostics = { matchedSelector: '', messageCount: 0 };

    function qs(selectors, root = document) {
        const list = Array.isArray(selectors) ? selectors : [selectors];
        for (const sel of list) {
            const el = root.querySelector(sel);
            if (el) return el;
        }
        return null;
    }

    function sleep(ms) {
        return new Promise(r => setTimeout(r, ms));
    }

    function normalizeText(text) {
        return (text || '').replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim();
    }

    function groupNamesMatch(actual, expected) {
        const a = normalizeText(actual).toLocaleLowerCase('vi');
        const e = normalizeText(expected).toLocaleLowerCase('vi');
        return Boolean(a && e && (a.includes(e) || e.includes(a)));
    }

    function setControlledInputValue(input, value) {
        const prototype = input instanceof HTMLTextAreaElement
            ? HTMLTextAreaElement.prototype
            : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
        if (setter) setter.call(input, value);
        else input.value = value;
        input.dispatchEvent(new InputEvent('input', {
            bubbles: true,
            inputType: 'insertText',
            data: value
        }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
    }

    function fnvHash(text) {
        const s = normalizeText(text).replace(/\s+/g, '');
        let h = 2166136261;
        for (let i = 0; i < s.length; i++) {
            h ^= s.charCodeAt(i);
            h = Math.imul(h, 16777619);
        }
        return (h >>> 0).toString(16).padStart(8, '0');
    }

    function http(method, path, body) {
        return new Promise((resolve, reject) => {
            GM_xmlhttpRequest({
                method,
                url: `http://${BRIDGE.host}:${BRIDGE.port}${path}`,
                headers: body ? { 'Content-Type': 'application/json' } : undefined,
                data: body ? JSON.stringify(body) : undefined,
                timeout: 8000,
                onload(resp) {
                    try {
                        resolve({
                            status: resp.status,
                            body: resp.responseText ? JSON.parse(resp.responseText) : {}
                        });
                    } catch (e) {
                        resolve({ status: resp.status, body: resp.responseText || '' });
                    }
                },
                onerror: reject,
                ontimeout: () => reject(new Error('bridge timeout'))
            });
        });
    }

    function detectRole() {
        const h = (location.hash || '').toLowerCase();
        if (h.includes('harvest')) {
            sessionStorage.setItem('zaloListingBotRole', 'harvest');
            return 'harvest';
        }
        if (h.includes('publish')) {
            sessionStorage.setItem('zaloListingBotRole', 'publish');
            return 'publish';
        }
        const remembered = sessionStorage.getItem('zaloListingBotRole');
        if (remembered === 'harvest' || remembered === 'publish') return remembered;
        return 'unknown';
    }

    function applyRoleTitle(role) {
        const base = document.title.replace(/^\[(Harvest|Publish)\]\s*/, '');
        if (role === 'harvest') document.title = '[Harvest] ' + base;
        else if (role === 'publish') document.title = '[Publish] ' + base;
    }

    function isExcludedElement(el) {
        if (!el) return true;
        for (const sel of SELECTORS.excludeRegions) {
            if (el.closest(sel)) return true;
        }
        if (el.closest(SELECTORS.composeBox[0]) || el.closest('[contenteditable="true"]')) {
            const ce = el.closest('[contenteditable]');
            if (ce && ce.getAttribute('contenteditable') === 'true') return true;
        }
        return false;
    }

    function getMessagePane() {
        return qs(SELECTORS.messagePane) || document.body;
    }

    function scoreMessageElement(el, pane) {
        if (!el || isExcludedElement(el)) return -9999;
        let score = 0;
        if (pane && pane.contains(el)) score += 2;
        const text = extractMessageText(el);
        if (text.length > 12) score += 3;
        if (extractMessageImages(el).length) score += 2;
        if (el.querySelector('img[src*="zdn.vn"], img[src*="blob:"]')) score += 1;
        return score;
    }

    function findMessageElements() {
        const pane = getMessagePane();
        const seen = new Set();
        const scored = [];
        let matchedSelector = '';

        for (const sel of SELECTORS.messageItemTiers) {
            const nodes = pane.querySelectorAll(sel);
            if (!nodes.length) continue;
            for (const el of nodes) {
                if (seen.has(el)) continue;
                seen.add(el);
                const score = scoreMessageElement(el, pane);
                if (score < 0) continue;
                if (!matchedSelector) matchedSelector = sel;
                scored.push({ el, score, selector: sel });
            }
        }

        // Zalo image bubbles sometimes expose only a stable CDN src. Walk up
        // to the nearest message-shaped ancestor instead of relying on classes.
        for (const image of pane.querySelectorAll('img[src*="zdn.vn"]')) {
            let candidate = image.parentElement;
            let best = null;
            for (let depth = 0; candidate && depth < 6; depth++, candidate = candidate.parentElement) {
                if (candidate === pane || isExcludedElement(candidate)) break;
                const score = scoreMessageElement(candidate, pane);
                if (score >= 4 && (!best || score > best.score))
                    best = { el: candidate, score, selector: 'img[src*="zdn.vn"] ancestor' };
            }
            if (best && !seen.has(best.el)) {
                seen.add(best.el);
                scored.push(best);
            }
        }

        if (!scored.length) {
            matchedSelector = 'div[contenteditable="false"]';
            const fallback = pane.querySelectorAll('div[contenteditable="false"]');
            for (const el of fallback) {
                if (seen.has(el) || isExcludedElement(el)) continue;
                const score = scoreMessageElement(el, pane);
                if (score < 1) continue;
                seen.add(el);
                scored.push({ el, score, selector: matchedSelector });
            }
        }

        const byDomOrder = [...scored].sort((a, b) => {
            const pos = a.el.compareDocumentPosition(b.el);
            if (pos & Node.DOCUMENT_POSITION_FOLLOWING) return -1;
            if (pos & Node.DOCUMENT_POSITION_PRECEDING) return 1;
            return 0;
        });

        lastDomDiagnostics = {
            matchedSelector: matchedSelector || (byDomOrder[0] ? byDomOrder[0].selector : ''),
            messageCount: byDomOrder.length
        };

        return byDomOrder.map(item => item.el);
    }

    function getConversationTitle() {
        const el = qs(SELECTORS.conversationTitle);
        return el ? normalizeText(el.innerText || el.textContent) : '';
    }

    function extractMessageText(item) {
        const textEl = qs(SELECTORS.messageText, item);
        if (textEl) return normalizeText(textEl.innerText || textEl.textContent);
        const clone = item.cloneNode(true);
        clone.querySelectorAll('img, button, svg, [class*="time"], [class*="avatar"]').forEach(n => n.remove());
        return normalizeText(clone.innerText || clone.textContent);
    }

    function extractMessageImages(item) {
        return [...item.querySelectorAll(SELECTORS.messageImage)]
            .map(img => img.currentSrc || img.src)
            .filter(Boolean);
    }

    function collectMessages() {
        const messages = [];
        for (const item of findMessageElements()) {
            const text = extractMessageText(item);
            const images = extractMessageImages(item);
            if (!text && !images.length) continue;
            const hash = fnvHash(text + images.join('|'));
            const nestedDuplicate = messages.some(message =>
                message.hash === hash &&
                (message.element.contains(item) || item.contains(message.element))
            );
            if (nestedDuplicate) continue;
            messages.push({
                element: item,
                text,
                images,
                hash
            });
        }
        return messages;
    }

    function scanConversation() {
        const messages = collectMessages();
        const lines = messages.map(m => m.text).filter(Boolean);
        return {
            group: getConversationTitle(),
            text: lines.join('\n'),
            messages: messages.map(m => ({ text: m.text, images: m.images, hash: m.hash })),
            message_count: messages.length,
            dom: lastDomDiagnostics
        };
    }

    function dumpDom() {
        const messages = collectMessages();
        return {
            role: BRIDGE.role,
            group: getConversationTitle(),
            matchedSelector: lastDomDiagnostics.matchedSelector,
            messageCount: messages.length,
            sampleTexts: messages.slice(-5).map(m => m.text.slice(0, 120))
        };
    }

    function findUnreadGroups() {
        const items = [];
        for (const sel of SELECTORS.sidebarItem) {
            document.querySelectorAll(sel).forEach(el => items.push(el));
        }
        const unread = [];
        const seen = new Set();
        for (const item of items) {
            const nameEl = item.querySelector('[class*="title"], [class*="name"]') || item;
            const name = normalizeText(nameEl.innerText || nameEl.textContent);
            if (!name || seen.has(name)) continue;
            seen.add(name);
            const badge = qs(SELECTORS.unreadBadge, item);
            const badgeText = badge ? normalizeText(badge.innerText || badge.textContent) : '';
            const hasUnread = badge && (
                /^\d{1,3}$/.test(badgeText) ||
                /tin nhắn mới|chưa đọc|unread/i.test(badgeText)
            );
            if (hasUnread) unread.push(name);
        }
        return unread;
    }

    async function focusCompose() {
        const box = qs(SELECTORS.composeBox);
        if (!box) throw new Error('Không tìm thấy ô soạn tin Zalo Web.');
        box.focus();
        box.click();
        await sleep(120);
        return true;
    }

    async function navigateToGroup(groupName) {
        if (!groupName) throw new Error('Tên nhóm rỗng.');
        const search = qs(SELECTORS.sidebarSearch);
        if (!search) throw new Error('Không tìm thấy ô tìm kiếm sidebar.');

        search.focus();
        search.click();
        await sleep(150);
        setControlledInputValue(search, '');
        await sleep(80);
        setControlledInputValue(search, groupName);
        await sleep(600);

        const target = groupName.toLowerCase();
        for (const sel of SELECTORS.sidebarItem) {
            for (const item of document.querySelectorAll(sel)) {
                const label = normalizeText(item.innerText || item.textContent);
                if (!label) continue;
                if (label.toLowerCase().includes(target) || target.includes(label.toLowerCase().slice(0, 20))) {
                    item.click();
                    await sleep(900);
                    const title = getConversationTitle();
                    if (groupNamesMatch(title, groupName))
                        return { ok: true, group: title };
                }
            }
        }

        search.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
        await sleep(900);
        const title = getConversationTitle();
        if (groupNamesMatch(title, groupName))
            return { ok: true, group: title };
        throw new Error('Không mở được nhóm: ' + groupName);
    }

    function requestImageBlob(url) {
        if (url.startsWith('blob:')) {
            return fetch(url).then(response => {
                if (!response.ok) throw new Error('Fetch ảnh thất bại: ' + response.status);
                return response.blob();
            });
        }
        return new Promise((resolve, reject) => {
            GM_xmlhttpRequest({
                method: 'GET',
                url,
                responseType: 'blob',
                timeout: 15000,
                onload(response) {
                    if (response.status < 200 || response.status >= 300) {
                        reject(new Error('Tải ảnh thất bại: HTTP ' + response.status));
                        return;
                    }
                    resolve(response.response);
                },
                onerror: () => reject(new Error('Không tải được ảnh từ CDN Zalo.')),
                ontimeout: () => reject(new Error('Timeout khi tải ảnh từ CDN Zalo.'))
            });
        });
    }

    async function copyImageBlobToClipboard(url) {
        const blob = await requestImageBlob(url);
        const type = blob.type || 'image/png';
        await navigator.clipboard.write([new ClipboardItem({ [type]: blob })]);
        return true;
    }

    async function findImagesNearAnchor(anchor, limit = 6) {
        const needle = (anchor || '').toLowerCase().slice(0, 40);
        const messages = collectMessages();
        const hits = [];
        for (let i = messages.length - 1; i >= 0; i--) {
            const msg = messages[i];
            if (needle && !msg.text.toLowerCase().includes(needle)) continue;
            if (msg.images.length) {
                for (const url of msg.images) hits.push({ url, text: msg.text });
                if (hits.length >= limit) break;
            }
            if (needle && msg.text.toLowerCase().includes(needle) && i > 0) {
                const prev = messages[i - 1];
                for (const url of prev.images) hits.push({ url, text: prev.text });
                if (hits.length >= limit) break;
            }
        }
        return hits.slice(0, limit);
    }

    async function listImagesForAnchor(anchor, limit = 6) {
        const found = await findImagesNearAnchor(anchor, limit);
        return { count: found.length, urls: found.map(item => item.url) };
    }

    async function copyImageByUrl(url) {
        if (!url) throw new Error('URL ảnh rỗng.');
        await copyImageBlobToClipboard(url);
        return { ok: true, url };
    }

    async function scrollToAnchor(anchor) {
        const needle = (anchor || '').toLowerCase();
        if (!needle) return false;
        for (const item of findMessageElements()) {
            if (extractMessageText(item).toLowerCase().includes(needle)) {
                item.scrollIntoView({ block: 'center' });
                await sleep(300);
                return true;
            }
        }
        return false;
    }

    async function registerRole() {
        try {
            applyRoleTitle(BRIDGE.role);
            await http('POST', '/api/register', {
                role: BRIDGE.role,
                title: document.title,
                url: location.href,
                ts: Date.now()
            });
        } catch (_) { /* bridge offline */ }
    }

    async function runCommand(cmd) {
        switch (cmd.action) {
            case 'ping':
                return { ok: true, role: BRIDGE.role, title: document.title, url: location.href };
            case 'navigate':
                if (BRIDGE.role !== 'harvest')
                    throw new Error('navigate chỉ chạy trên cửa sổ Harvest.');
                return await navigateToGroup(cmd.group);
            case 'scan':
                if (BRIDGE.role !== 'harvest')
                    throw new Error('scan chỉ chạy trên cửa sổ Harvest.');
                return scanConversation();
            case 'dump_dom':
                if (BRIDGE.role !== 'harvest')
                    throw new Error('dump_dom chỉ chạy trên Harvest.');
                return dumpDom();
            case 'title':
                return { group: getConversationTitle() };
            case 'unread':
                if (BRIDGE.role !== 'harvest') return { groups: [] };
                return { groups: findUnreadGroups() };
            case 'focus_compose':
                await focusCompose();
                return { ok: true };
            case 'find_images':
                if (BRIDGE.role !== 'harvest')
                    throw new Error('find_images chỉ chạy trên Harvest.');
                if (cmd.anchor) await scrollToAnchor(cmd.anchor);
                return await listImagesForAnchor(cmd.anchor, cmd.limit || 6);
            case 'copy_image':
                if (BRIDGE.role !== 'harvest')
                    throw new Error('copy_image chỉ chạy trên Harvest.');
                return await copyImageByUrl(cmd.url);
            case 'copy_text':
                await navigator.clipboard.writeText(cmd.text || '');
                return { ok: true };
            default:
                throw new Error('Unknown command: ' + cmd.action);
        }
    }

    function commandAllowedForRole(cmd) {
        if (!cmd || !cmd.action) return false;
        if (cmd.action === 'ping' || cmd.action === 'focus_compose' || cmd.action === 'title') return true;
        if (BRIDGE.role === 'harvest') return true;
        if (BRIDGE.role === 'publish') return cmd.action === 'focus_compose';
        return false;
    }

    async function pollCommands() {
        if (BRIDGE.role === 'unknown' || pollBusy) return;
        pollBusy = true;
        let commandId = '';
        try {
            const resp = await http('GET', '/api/command?role=' + encodeURIComponent(BRIDGE.role));
            if (!resp.body || !resp.body.action) return;
            commandId = resp.body.id || '';
            if (!commandAllowedForRole(resp.body)) return;
            const result = await runCommand(resp.body);
            await http('POST', '/api/command-result', {
                id: commandId,
                ok: true,
                result
            });
        } catch (err) {
            if (!commandId) return;
            try {
                await http('POST', '/api/command-result', {
                    id: commandId,
                    ok: false,
                    error: String(err.message || err)
                });
            } catch (_) { /* ignore */ }
        } finally {
            pollBusy = false;
        }
    }

    async function pushLatestMessage() {
        if (BRIDGE.role !== 'harvest') return;
        const messages = collectMessages();
        if (!messages.length) return;
        const latest = messages[messages.length - 1];
        const hash = latest.hash + '|' + getConversationTitle();
        if (hash === lastPushHash) return;
        lastPushHash = hash;

        await http('POST', '/api/event', {
            type: 'message',
            group: getConversationTitle(),
            text: latest.text,
            images: latest.images,
            hasImage: latest.images.length > 0,
            hash: latest.hash,
            ts: Date.now()
        });
    }

    function schedulePush() {
        if (observerDebounce) clearTimeout(observerDebounce);
        observerDebounce = setTimeout(() => {
            pushLatestMessage().catch(() => {});
        }, 250);
    }

    function startObserver() {
        if (BRIDGE.role !== 'harvest') return;
        const root = getMessagePane();
        if (observer) observer.disconnect();
        observer = new MutationObserver(() => schedulePush());
        observer.observe(root, { childList: true, subtree: true });
    }

    async function bootstrap() {
        BRIDGE.role = detectRole();
        applyRoleTitle(BRIDGE.role);
        console.info('[ZaloBot] role=' + BRIDGE.role, location.href);

        if (BRIDGE.role === 'unknown') {
            console.warn('[ZaloBot] Thiếu #harvest hoặc #publish trong URL — script idle.');
            return;
        }

        await registerRole();
        if (registerTimer) clearInterval(registerTimer);
        registerTimer = setInterval(registerRole, 5000);

        if (BRIDGE.role === 'harvest') startObserver();

        if (pollTimer) clearInterval(pollTimer);
        pollTimer = setInterval(pollCommands, BRIDGE.pollMs);

        try {
            const health = await http('GET', '/api/health');
            if (health.body && health.body.ok) {
                console.info('[ZaloBot] AHK bridge connected', health.body);
            }
        } catch (_) {
            console.info('[ZaloBot] AHK bridge chưa sẵn sàng.');
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', bootstrap);
    } else {
        bootstrap();
    }
})();
