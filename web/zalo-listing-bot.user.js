// ==UserScript==
// @name         Zalo Listing Bot — Web Bridge
// @namespace    zalo-listing-bot
// @version      4.1.6
// @description  Single-tab Zalo Web: harvest source groups then switch to sale group in-place
// @match        *://chat.zalo.me/*
// @match        *://chat.zalo.me/
// @match        *://*.zalo.me/*
// @include      *://chat.zalo.me/*
// @grant        GM_xmlhttpRequest
// @grant        window.onurlchange
// @connect      127.0.0.1
// @connect      zdn.vn
// @connect      zaloapp.com
// @connect      zalo.me
// @run-at       document-start
// ==/UserScript==

(function () {
    'use strict';

    const SCRIPT_VERSION = '4.1.6';
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
            'input[placeholder*="Tìm kiếm"]',
            'input[aria-label*="Tìm"]',
            'input[aria-label*="tim"]',
            'input[type="search"]',
            '[class*="search"] input',
            '[class*="search-input"]',
            '[class*="search"] [contenteditable="true"]',
            '[class*="sidebar"] input[type="text"]',
            '[class*="left-side"] input[type="text"]',
            '[class*="conv-list"] input[type="text"]'
        ],
        conversationTitle: [
            '[class*="header-title"]',
            '[class*="conv-title"]',
            '[class*="thread-title"]',
            '[class*="chat-header"] [class*="title"]',
            '[class*="chat-header"] [class*="name"]',
            '[class*="header"] [class*="title"]',
            '[class*="header"] [class*="name"]',
            'header h1',
            'header h2',
            'header [class*="name"]'
        ],
        sidebarItem: [
            '[class*="conv-item"]',
            '[class*="conversation-item"]',
            '[class*="chat-item"]',
            '[role="listitem"]'
        ],
        searchResultItem: [
            '[class*="search-result"] [class*="item"]',
            '[class*="SearchResult"]',
            '[class*="search-list"] [class*="item"]',
            '[class*="global-search"] [class*="item"]',
            '[class*="result-list"] [class*="item"]',
            '[class*="search"] [class*="conv-item"]',
            '[class*="search"] [class*="conversation"]'
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
    let outputGroupNames = [];
    let eventsPaused = false;

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

    function normalizeGroupName(name) {
        return normalizeText(name)
            .toLocaleLowerCase('vi')
            .replace(/[“”„‟]/g, '"')
            .replace(/\u00a0/g, ' ')
            .replace(/\s+/g, ' ')
            .trim();
    }

    function groupNamesMatch(actual, expected) {
        const e = normalizeGroupName(expected);
        if (!e) return false;
        // Search-result containers often include preview text on later lines.
        // Match only a complete title line; substring matching can open a
        // similarly named group and leave the previous conversation active.
        return normalizeText(actual)
            .split('\n')
            .some(line => normalizeGroupName(line) === e);
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
        const url = `http://${BRIDGE.host}:${BRIDGE.port}${path}`;
        return new Promise((resolve, reject) => {
            GM_xmlhttpRequest({
                method,
                url,
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
                onerror(err) {
                    reject(err || new Error('gm_onerror'));
                },
                ontimeout() {
                    reject(new Error('bridge timeout'));
                }
            });
        });
    }

    function detectRole() {
        // Zalo Web single-session: one tab handles harvest + publish in-place.
        sessionStorage.setItem('zaloListingBotRole', 'bot');
        return 'bot';
    }

    function applyRoleTitle() {
        if (!document.title) return;
        const base = document.title.replace(/^\[(ZaloBot|Harvest|Publish)\]\s*/, '');
        const next = '[ZaloBot] ' + (base || 'Zalo');
        if (document.title !== next)
            document.title = next;
    }

    function showStatusBadge() {
        if (document.getElementById('zalo-listing-bot-badge')) return;
        const badge = document.createElement('div');
        badge.id = 'zalo-listing-bot-badge';
        badge.textContent = 'ZaloBot ON';
        badge.style.cssText = [
            'position:fixed', 'top:8px', 'right:8px', 'z-index:2147483647',
            'background:#0068ff', 'color:#fff', 'font:12px/1.4 sans-serif',
            'padding:4px 8px', 'border-radius:4px', 'pointer-events:none'
        ].join(';');
        (document.body || document.documentElement).appendChild(badge);
    }

    function isOutputGroup(name) {
        const actual = normalizeText(name).toLocaleLowerCase('vi');
        if (!actual) return false;
        return outputGroupNames.some(expected => groupNamesMatch(actual, expected));
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
        if (el) return normalizeText(el.innerText || el.textContent);
        const header = qs([
            '[class*="chat-header"]',
            '[class*="header-chat"]',
            'header'
        ]);
        if (header) {
            const name = header.querySelector(
                '[class*="title"], [class*="name"], h1, h2, span');
            if (name) return normalizeText(name.innerText || name.textContent);
        }
        return '';
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

    function associateImagesWithText(messages) {
        const result = [];
        let pendingImages = [];
        for (let index = 0; index < messages.length; index++) {
            const message = messages[index];
            if (!message.text && message.images.length) {
                pendingImages.push(...message.images);
                continue;
            }
            if (!message.text) continue;
            const images = [...new Set([...pendingImages, ...message.images])];
            pendingImages = [];
            result.push({
                text: message.text,
                images,
                hash: fnvHash(message.text + images.join('|')),
                dom_index: index
            });
        }
        return result;
    }

    function scanConversation() {
        const messages = associateImagesWithText(collectMessages());
        const lines = messages.map(m => m.text).filter(Boolean);
        const imageTotal = messages.reduce((sum, m) => sum + m.images.length, 0);
        // #region agent log
        fetch('http://127.0.0.1:7932/ingest/d1ffc0de-e0fa-4c76-b9ea-e4ddb6aeec2d',{method:'POST',headers:{'Content-Type':'application/json','X-Debug-Session-Id':'850be2'},body:JSON.stringify({sessionId:'850be2',location:'user.js:scanConversation',message:'scan_done',data:{group:getConversationTitle(),msgCount:messages.length,textLen:lines.join('\n').length,imageTotal,selector:lastDomDiagnostics.matchedSelector},timestamp:Date.now(),hypothesisId:'H3',runId:'pre-fix'})}).catch(()=>{});
        // #endregion
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

    function getSidebarRoot() {
        return qs([
            '[class*="left-side"]',
            '[class*="sidebar"]',
            '[class*="conv-list"]',
            'nav[class*="side"]'
        ]) || document.body;
    }

    function collectGroupLabels(selectors, root = document) {
        const labels = [];
        const seen = new Set();
        for (const sel of selectors) {
            for (const item of root.querySelectorAll(sel)) {
                const label = normalizeText(item.innerText || item.textContent);
                if (!label || seen.has(label)) continue;
                seen.add(label);
                labels.push({ item, label });
            }
        }
        return labels;
    }

    function dismissBrowserUi() {
        for (let i = 0; i < 2; i++) {
            document.dispatchEvent(new KeyboardEvent('keydown', {
                key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true
            }));
        }
    }

    function findSidebarSearchInput() {
        const vw = window.innerWidth || document.documentElement.clientWidth || 1200;
        const maxRight = vw * 0.52;

        for (const sel of SELECTORS.sidebarSearch) {
            for (const el of document.querySelectorAll(sel)) {
                if (isExcludedElement(el)) continue;
                if (el.closest('[class*="chat-input"]') || el.closest('[class*="compose"]')) continue;
                const rect = el.getBoundingClientRect();
                if (rect.width <= 0 || rect.height <= 0) continue;
                if (rect.right <= maxRight) return el;
            }
        }

        for (const el of document.querySelectorAll(
            'input[type="text"], input[type="search"], input:not([type]), [contenteditable="true"]')) {
            if (isExcludedElement(el)) continue;
            if (el.closest('[class*="chat-input"]') || el.closest('[class*="compose"]')) continue;
            const rect = el.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0 || rect.right > maxRight) continue;
            const hint = [
                el.getAttribute('placeholder') || '',
                el.getAttribute('aria-label') || '',
                el.getAttribute('title') || ''
            ].join(' ').toLowerCase();
            if (/tìm|tim|search/.test(hint) || rect.top < 220)
                return el;
        }
        return null;
    }

    async function ensureSidebarSearchVisible() {
        let search = findSidebarSearchInput();
        if (search) return search;

        const sidebar = getSidebarRoot();
        const triggers = sidebar.querySelectorAll(
            'button[class*="search"], [class*="search"] button, [class*="search-icon"],'
            + '[aria-label*="Tìm"], [aria-label*="tim"], [title*="Tìm"], [title*="tim"]');
        for (const btn of triggers) {
            btn.click();
            await sleep(500);
            search = findSidebarSearchInput();
            if (search) return search;
        }
        return findSidebarSearchInput();
    }

    async function typeSearchQuery(search, text) {
        search.focus();
        search.click();
        await sleep(120);
        if (search.isContentEditable) {
            search.textContent = '';
            search.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
            await sleep(80);
            search.textContent = text;
            search.dispatchEvent(new InputEvent('input', {
                bubbles: true,
                inputType: 'insertText',
                data: text
            }));
            search.dispatchEvent(new Event('change', { bubbles: true }));
            return;
        }
        setControlledInputValue(search, '');
        await sleep(80);
        setControlledInputValue(search, text);
    }

    async function tryOpenMatchingItem(items, groupName) {
        for (const entry of items) {
            if (!groupNamesMatch(entry.label, groupName))
                continue;
            entry.item.scrollIntoView({ block: 'nearest' });
            entry.item.click();
            await sleep(1200);
            const title = getConversationTitle();
            if (groupNamesMatch(title, groupName))
                return { ok: true, group: title };
        }
        return null;
    }

    async function navigateToGroup(groupName) {
        if (!groupName) throw new Error('Tên nhóm rỗng.');
        dismissBrowserUi();
        await sleep(200);
        const search = await ensureSidebarSearchVisible();
        if (!search) throw new Error('Không tìm thấy ô tìm kiếm sidebar Zalo.');
        // #region agent log
        fetch('http://127.0.0.1:7932/ingest/d1ffc0de-e0fa-4c76-b9ea-e4ddb6aeec2d',{method:'POST',headers:{'Content-Type':'application/json','X-Debug-Session-Id':'850be2'},body:JSON.stringify({sessionId:'850be2',location:'user.js:navigateToGroup',message:'sidebar_search_focus',data:{group:groupName,tag:search.tagName,placeholder:search.getAttribute('placeholder')||'',ariaLabel:search.getAttribute('aria-label')||'',className:(search.className||'').slice(0,80)},timestamp:Date.now(),hypothesisId:'H9',runId:'post-fix'})}).catch(()=>{});
        // #endregion

        search.scrollIntoView({ block: 'nearest' });
        await typeSearchQuery(search, groupName);
        await sleep(1200);

        const sidebarRoot = getSidebarRoot();
        let opened = await tryOpenMatchingItem(
            collectGroupLabels(SELECTORS.sidebarItem, sidebarRoot),
            groupName
        );
        if (opened) return opened;

        opened = await tryOpenMatchingItem(
            collectGroupLabels(SELECTORS.searchResultItem, document),
            groupName
        );
        if (opened) return opened;

        opened = await tryOpenMatchingItem(
            collectGroupLabels(SELECTORS.sidebarItem, document),
            groupName
        );
        if (opened) return opened;

        search.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
        await sleep(1200);
        const title = getConversationTitle();
        if (groupNamesMatch(title, groupName))
            return { ok: true, group: title };
        // #region agent log
        const diagLabels = collectGroupLabels(
            [...SELECTORS.searchResultItem, ...SELECTORS.sidebarItem],
            document
        ).slice(0, 6).map(entry => entry.label.slice(0, 80));
        fetch('http://127.0.0.1:7932/ingest/d1ffc0de-e0fa-4c76-b9ea-e4ddb6aeec2d',{method:'POST',headers:{'Content-Type':'application/json','X-Debug-Session-Id':'850be2'},body:JSON.stringify({sessionId:'850be2',location:'user.js:navigateToGroup',message:'navigate_fail',data:{expected:groupName,titleAfter:title,searchLen:groupName.length,labelSamples:diagLabels,url:location.href},timestamp:Date.now(),hypothesisId:'H2',runId:'post-fix'})}).catch(()=>{});
        // #endregion
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

    function blobToBase64(blob) {
        return new Promise((resolve, reject) => {
            if (blob.size > 12 * 1024 * 1024) {
                reject(new Error('Ảnh vượt giới hạn 12 MB.'));
                return;
            }
            const reader = new FileReader();
            reader.onload = () => {
                const value = String(reader.result || '');
                const comma = value.indexOf(',');
                resolve(comma >= 0 ? value.slice(comma + 1) : value);
            };
            reader.onerror = () => reject(new Error('Không đọc được blob ảnh.'));
            reader.readAsDataURL(blob);
        });
    }

    async function fetchImageData(url) {
        if (!url) throw new Error('URL ảnh rỗng.');
        const blob = await requestImageBlob(url);
        return {
            data_base64: await blobToBase64(blob),
            mime: blob.type || 'image/png',
            size: blob.size,
            url
        };
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
            applyRoleTitle();
            await http('POST', '/api/register', {
                role: 'bot',
                version: SCRIPT_VERSION,
                title: document.title,
                url: location.href,
                ts: Date.now()
            });
            // Chrome may throttle the faster command timer in background tabs.
            // Process a pending command after every successful heartbeat so
            // startup ping and later commands cannot remain stuck indefinitely.
            await pollCommands();
        } catch (_) { /* bridge offline */ }
    }

    async function refreshPublicConfig() {
        try {
            const resp = await http('GET', '/api/config');
            const groups = resp.body && resp.body.output_groups;
            if (Array.isArray(groups))
                outputGroupNames = groups.map(name => String(name || ''));
        } catch (_) { /* bridge offline */ }
    }

    async function runCommand(cmd) {
        switch (cmd.action) {
            case 'ping':
                return { ok: true, role: 'bot', title: document.title, url: location.href };
            case 'navigate':
                return await navigateToGroup(cmd.group);
            case 'scan':
                return scanConversation();
            case 'dump_dom':
                return dumpDom();
            case 'title':
                return { group: getConversationTitle() };
            case 'unread':
                return { groups: findUnreadGroups() };
            case 'focus_compose':
                await focusCompose();
                return { ok: true };
            case 'find_images':
                if (cmd.anchor) await scrollToAnchor(cmd.anchor);
                return await listImagesForAnchor(cmd.anchor, cmd.limit || 6);
            case 'copy_image':
                return await copyImageByUrl(cmd.url);
            case 'fetch_image':
                return await fetchImageData(cmd.url);
            case 'copy_text':
                await navigator.clipboard.writeText(cmd.text || '');
                return { ok: true };
            case 'pause_events':
                eventsPaused = true;
                return { ok: true };
            case 'resume_events':
                eventsPaused = false;
                return { ok: true };
            default:
                throw new Error('Unknown command: ' + cmd.action);
        }
    }

    async function pollCommands() {
        if (pollBusy) return;
        pollBusy = true;
        let commandId = '';
        try {
            const resp = await http('GET', '/api/command?role=bot');
            if (!resp.body || !resp.body.action) return;
            commandId = resp.body.id || '';
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
        if (eventsPaused) return;
        const group = getConversationTitle();
        if (isOutputGroup(group)) return;
        const messages = collectMessages();
        if (!messages.length) return;
        const latest = messages[messages.length - 1];
        const hash = latest.hash + '|' + group;
        if (hash === lastPushHash) return;
        lastPushHash = hash;

        await http('POST', '/api/event', {
            type: 'message',
            group,
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
        const root = getMessagePane();
        if (observer) observer.disconnect();
        observer = new MutationObserver(() => schedulePush());
        observer.observe(root, { childList: true, subtree: true });
    }

    let bootstrapped = false;

    async function bootstrap() {
        if (bootstrapped) {
            applyRoleTitle();
            showStatusBadge();
            await registerRole();
            return;
        }
        bootstrapped = true;
        BRIDGE.role = detectRole();
        applyRoleTitle();
        showStatusBadge();
        console.info('[ZaloBot] single-tab role=bot', location.href);

        await registerRole();
        await refreshPublicConfig();
        if (registerTimer) clearInterval(registerTimer);
        registerTimer = setInterval(() => {
            applyRoleTitle();
            showStatusBadge();
            registerRole();
            refreshPublicConfig();
            pollCommands();
        }, 2000);

        startObserver();

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

    function startWhenReady() {
        bootstrap().catch(err => console.warn('[ZaloBot] bootstrap', err));
    }

    startWhenReady();
    document.addEventListener('DOMContentLoaded', startWhenReady);
    window.addEventListener('load', startWhenReady);
    window.addEventListener('pageshow', startWhenReady);
    window.addEventListener('focus', () => registerRole());
    document.addEventListener('visibilitychange', () => {
        if (!document.hidden) registerRole();
    });
    if (window.onurlchange === null)
        window.addEventListener('urlchange', startWhenReady);
})();
