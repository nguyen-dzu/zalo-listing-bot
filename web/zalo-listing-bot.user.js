// ==UserScript==
// @name         Zalo Listing Bot — Web Bridge
// @namespace    zalo-listing-bot
// @version      4.3.10
// @description  Single-tab Zalo Web: harvest source groups then switch to sale group in-place
// @match        *://chat.zalo.me/*
// @match        *://chat.zalo.me/
// @match        *://*.zalo.me/*
// @include      *://chat.zalo.me/*
// @grant        GM_xmlhttpRequest
// @grant        window.onurlchange
// @connect      127.0.0.1
// @connect      zdn.vn
// @connect      zadn.vn
// @connect      zaloapp.com
// @connect      dlfl.vn
// @connect      zalo.me
// @connect      *
// @run-at       document-start
// ==/UserScript==

(function () {
    'use strict';

    const SCRIPT_VERSION = '4.3.10';
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
        messageImage: 'img[src*="blob:"], img[src*="zdn"], img[src*="zadn"], img[src*="zalo"], img[data-src*="zdn"], img[data-src*="blob"], img[data-src*="zadn"], img[class*="image"], img[class*="photo"]',
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
        if (el.querySelector('img, video, [class*="photo"], [class*="album"], [class*="media"]')) score += 1;
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
        for (const media of pane.querySelectorAll('img, video')) {
            let candidate = media.parentElement;
            let best = null;
            for (let depth = 0; candidate && depth < 8; depth++, candidate = candidate.parentElement) {
                if (candidate === pane || isExcludedElement(candidate)) break;
                const score = scoreMessageElement(candidate, pane);
                if (score >= 3 && (!best || score > best.score))
                    best = { el: candidate, score, selector: 'media ancestor' };
            }
            if (best && !seen.has(best.el)) {
                seen.add(best.el);
                scored.push(best);
            }
        }

        // Some Zalo builds no longer expose a stable message-item wrapper.
        // Keep the text node itself as a last structured source; standalone
        // image bubbles collected above are associated by DOM order later.
        const hasTextCandidate = scored.some(item =>
            extractMessageText(item.el).length > 0);
        if (!hasTextCandidate) {
            for (const sel of SELECTORS.messageText) {
                for (const el of pane.querySelectorAll(sel)) {
                    if (seen.has(el) || isExcludedElement(el)) continue;
                    const text = extractMessageText(el);
                    if (!text) continue;
                    seen.add(el);
                    scored.push({ el, score: 3, selector: `text fallback: ${sel}` });
                    if (!matchedSelector) matchedSelector = `text fallback: ${sel}`;
                }
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
        const parts = [];
        const seen = new Set();
        for (const sel of SELECTORS.messageText) {
            for (const el of item.querySelectorAll(sel)) {
                const t = normalizeText(el.innerText || el.textContent);
                if (!t || seen.has(t)) continue;
                seen.add(t);
                parts.push(t);
            }
        }
        if (parts.length) {
            parts.sort((a, b) => b.length - a.length);
            const kept = [];
            for (const p of parts) {
                if (!kept.some(k => k.includes(p)))
                    kept.push(p);
            }
            return kept.join('\n');
        }
        const clone = item.cloneNode(true);
        clone.querySelectorAll('img, button, svg, [class*="time"], [class*="avatar"]').forEach(n => n.remove());
        return normalizeText(clone.innerText || clone.textContent);
    }

    function classifyTimeValue(value) {
        const raw = String(value || '').trim();
        if (!raw) return '';
        if (/^\d{13}$/.test(raw)) return 'epoch_ms';
        if (/^\d{10}$/.test(raw)) return 'epoch_s';
        if (/\b\d{1,2}:\d{2}\b/.test(raw) && /\b\d{1,2}[\/.-]\d{1,2}/.test(raw))
            return 'date_time';
        if (/\b\d{1,2}:\d{2}\b/.test(raw)) return 'clock';
        if (/\b\d{1,2}[\/.-]\d{1,2}(?:[\/.-]\d{2,4})?\b/.test(raw))
            return 'date';
        return 'other';
    }

    function timeValueShape(value) {
        return String(value || '')
            .trim()
            .replace(/\d/g, '#')
            .replace(/[A-Za-zÀ-ỹ]/g, 'a')
            .replace(/\s+/g, ' ')
            .slice(0, 48);
    }

    function inspectMessageTime(item) {
        const nodes = [
            item,
            ...item.querySelectorAll(
                'time, [class*="time"], [data-time], [data-timestamp], [datetime]')
        ];
        const values = [];
        let structured = false;
        for (const node of nodes) {
            for (const attr of ['datetime', 'data-time', 'data-timestamp', 'title', 'aria-label']) {
                const value = node.getAttribute && node.getAttribute(attr);
                if (!value) continue;
                if (attr === 'datetime' || attr === 'data-time' || attr === 'data-timestamp')
                    structured = true;
                values.push(value);
            }
            if (node !== item) {
                const text = normalizeText(node.innerText || node.textContent || '');
                if (text) values.push(text);
            }
        }
        const kinds = [...new Set(values.map(classifyTimeValue).filter(Boolean))];
        const shapes = [...new Set(values.map(timeValueShape).filter(Boolean))].slice(0, 4);
        return { found: values.length > 0, structured, kinds, shapes };
    }

    function isPlaceholderImageSrc(src) {
        const value = String(src || '').trim().toLowerCase();
        if (!value || value === 'about:blank') return true;
        if (value.startsWith('data:image/gif')) return true;
        if (value.startsWith('data:image/png') && value.length < 180) return true;
        if (value.startsWith('data:image/jpeg') && value.length < 180) return true;
        return false;
    }

    function mediaElementSize(el) {
        if (!el) return { w: 0, h: 0 };
        const rect = el.getBoundingClientRect ? el.getBoundingClientRect() : { width: 0, height: 0 };
        const w = el.naturalWidth || el.videoWidth || el.width || rect.width || 0;
        const h = el.naturalHeight || el.videoHeight || el.height || rect.height || 0;
        return { w, h };
    }

    function isSizedMessageMedia(el) {
        const { w, h } = mediaElementSize(el);
        return w >= 44 && h >= 44;
    }

    function isChatImageUrl(url, contextEl) {
        const value = String(url || '').trim();
        if (isPlaceholderImageSrc(value)) return false;
        const lower = value.toLowerCase();
        if (/avatar|emoji|sticker|icon|logo|badge|thumb-default|favicon/i.test(lower))
            return false;
        if (lower.includes('blob:')
            || lower.includes('zdn.vn')
            || lower.includes('zadn.vn')
            || lower.includes('dlfl.vn')
            || lower.includes('photo.')
            || lower.includes('zalo')
            || lower.includes('chat-photo')
            || lower.includes('chat-img'))
            return true;
        if (contextEl && isSizedMessageMedia(contextEl)
            && (lower.startsWith('https://') || lower.startsWith('http://')))
            return true;
        return false;
    }

    function parseSrcsetValue(srcset) {
        const raw = String(srcset || '').trim();
        if (!raw) return '';
        return raw.split(',')[0].trim().split(/\s+/)[0] || '';
    }

    function resolveImageUrl(img) {
        if (!img) return '';
        const candidates = [
            img.currentSrc,
            img.src,
            img.getAttribute('data-src'),
            img.getAttribute('data-original'),
            img.getAttribute('data-url'),
            img.getAttribute('data-lazy-src'),
            img.getAttribute('data-thumb'),
            parseSrcsetValue(img.srcset || img.getAttribute('srcset'))
        ];
        let parent = img.parentElement;
        for (let depth = 0; parent && depth < 4; depth++, parent = parent.parentElement) {
            candidates.push(
                parent.getAttribute('data-src'),
                parent.getAttribute('data-url'),
                parent.getAttribute('data-original'),
                parent.getAttribute('data-thumb')
            );
        }
        for (const candidate of candidates) {
            if (isChatImageUrl(candidate, img)) return candidate;
        }
        return '';
    }

    function extractVideoUrls(item) {
        const urls = [];
        const seen = new Set();
        const push = (url) => {
            if (!url || seen.has(url)) return;
            seen.add(url);
            urls.push(url);
        };
        for (const video of item.querySelectorAll('video')) {
            if (isAvatarImage(video)) continue;
            const candidates = [
                video.poster,
                video.getAttribute('poster'),
                video.currentSrc,
                video.src,
                video.getAttribute('data-src'),
                video.getAttribute('data-url')
            ];
            for (const candidate of candidates) {
                if (isChatImageUrl(candidate, video))
                    push(candidate);
            }
        }
        return urls;
    }

    function isAvatarImage(img) {
        if (!img || !img.closest) return false;
        if (img.closest('[class*="avatar"], [class*="user-photo"], [class*="profile-photo"]'))
            return true;
        const { w, h } = mediaElementSize(img);
        if (w > 0 && h > 0 && w <= 52 && h <= 52) return true;
        const cls = String(img.className || '') + ' '
            + String(img.parentElement && img.parentElement.className || '');
        return /avatar|user-photo|profile/i.test(cls);
    }

    function isPhotoGridImage(img) {
        return !!(img && img.closest
            && img.closest('[class*="photo"], [class*="album"], [class*="media"], [class*="grid"], [class*="thumb"]'));
    }

    function extractBackgroundImageUrls(root) {
        const urls = [];
        const seen = new Set();
        const push = (url, el) => {
            if (!isChatImageUrl(url, el) || seen.has(url)) return;
            seen.add(url);
            urls.push(url);
        };
        for (const el of root.querySelectorAll('[style*="background"]')) {
            if (el.closest('[class*="avatar"]')) continue;
            const style = el.getAttribute('style') || '';
            const re = /url\(\s*['"]?([^'")]+)['"]?\s*\)/gi;
            let match;
            while ((match = re.exec(style)))
                push(match[1], el);
        }
        for (const el of root.querySelectorAll('[data-src], [data-url], [data-original], [data-thumb]')) {
            if (el.tagName === 'IMG' || el.tagName === 'VIDEO') continue;
            if (el.closest('[class*="avatar"]')) continue;
            push(el.getAttribute('data-src')
                || el.getAttribute('data-url')
                || el.getAttribute('data-original')
                || el.getAttribute('data-thumb'), el);
        }
        return urls;
    }

    function isCommunityCardImage(img) {
        if (!img || !img.closest) return false;
        const { w, h } = mediaElementSize(img);
        const wide = w >= 240 && h > 0 && w / h >= 2.0;
        const album = img.closest('[class*="album"], [class*="grid"]');
        const inAlbum = !!(album && album.querySelectorAll('img').length >= 2);
        if (inAlbum && !wide) return false;
        const skipSelectors = [
            '[class*="link"]', '[class*="preview"]', '[class*="card"]',
            '[class*="share"]', '[class*="og-"]', '[class*="banner"]',
            '[class*="community"]', '[class*="group-info"]',
            '[class*="article"]', '[class*="rich-link"]'
        ];
        for (const sel of skipSelectors) {
            const box = img.closest(sel);
            if (!box) continue;
            const text = normalizeText(box.innerText || box.textContent || '');
            if (/cộng đồng|community|cho thuê chdv|link nhóm|tham gia|dự án/i.test(text))
                return true;
        }
        let el = img.parentElement;
        for (let depth = 0; el && depth < 5; depth++, el = el.parentElement) {
            const text = normalizeText(el.innerText || el.textContent || '');
            if (text.length > 180) break;
            if (/cộng đồng|community|link\s+nhóm|tham\s+gia\s+cộng\s+đồng|dự án/i.test(text))
                return true;
        }
        if (wide) return true;
        return false;
    }

    function isPinnedRegion(el) {
        if (!el || !el.closest) return false;
        return !!el.closest(
            '[class*="pin-msg"], [class*="PinMsg"], [class*="pinned-msg"],'
            + '[class*="pin-bar"], [class*="pinBar"], header [class*="pin"]');
    }

    function isPromoBannerImage(img, item) {
        if (!img) return false;
        if (isPinnedRegion(img) || isPinnedRegion(item)) return true;
        if (isCommunityCardImage(img)) return true;
        const { w, h } = mediaElementSize(img);
        const album = img.closest('[class*="album"], [class*="grid"]');
        const inAlbum = !!(album && album.querySelectorAll('img').length >= 2);
        if (!inAlbum && w >= 280 && h > 0 && w / h >= 2.0) return true;
        const t = normalizeText((item && (item.innerText || item.textContent)) || '');
        if (/cộng đồng|dự án|home\s*365|link nhóm/i.test(t)
            && !/giá|trống sẵn|mã phòng|địa chỉ/i.test(t))
            return true;
        return false;
    }

    function extractMessageImages(item) {
        const urls = [];
        const seen = new Set();
        const push = (url) => {
            if (!url || seen.has(url)) return;
            seen.add(url);
            urls.push(url);
        };

        for (const img of item.querySelectorAll('img')) {
            if (isAvatarImage(img) || isPromoBannerImage(img, item)) continue;
            let url = resolveImageUrl(img);
            if (!url && isPhotoGridImage(img) && isSizedMessageMedia(img))
                url = img.currentSrc || img.src || img.getAttribute('data-src') || '';
            if (url) push(url);
        }

        for (const source of item.querySelectorAll('picture source[srcset], source[srcset]')) {
            const url = parseSrcsetValue(source.srcset || source.getAttribute('srcset'));
            if (isChatImageUrl(url, source)) push(url);
        }

        for (const url of extractBackgroundImageUrls(item))
            push(url);

        for (const url of extractVideoUrls(item))
            push(url);

        return urls;
    }

    function probeMessagePaneImages() {
        const pane = getMessagePane();
        const imgs = pane ? pane.querySelectorAll('img') : [];
        const videos = pane ? pane.querySelectorAll('video') : [];
        const samples = [];
        let sized = 0;
        let resolved = 0;
        for (const img of imgs) {
            if (isAvatarImage(img)) continue;
            if (isSizedMessageMedia(img)) sized++;
            const url = resolveImageUrl(img);
            if (url) resolved++;
            if (samples.length < 8) {
                samples.push({
                    w: Math.round(mediaElementSize(img).w),
                    h: Math.round(mediaElementSize(img).h),
                    src: String(img.src || '').slice(0, 120),
                    dataSrc: String(img.getAttribute('data-src') || '').slice(0, 120),
                    resolved: String(url || '').slice(0, 120),
                    grid: isPhotoGridImage(img)
                });
            }
        }
        return {
            imgTotal: imgs.length,
            videoTotal: videos.length,
            sized,
            resolved,
            samples,
            selector: lastDomDiagnostics.matchedSelector
        };
    }

    function extractMessageTimeMs(item) {
        const nodes = [
            item,
            ...item.querySelectorAll(
                'time, [data-time], [data-timestamp], [datetime], [class*="time"]')
        ];
        for (const node of nodes) {
            if (!node.getAttribute) continue;
            for (const attr of ['data-timestamp', 'datetime', 'data-time']) {
                const value = String(node.getAttribute(attr) || '').trim();
                if (!value) continue;
                if (/^\d{13}$/.test(value)) return Number(value);
                if (/^\d{10}$/.test(value)) return Number(value) * 1000;
                const parsed = Date.parse(value);
                if (!Number.isNaN(parsed)) return parsed;
            }
        }
        const clock = String(item.innerText || '').match(/\b(\d{1,2}):(\d{2})\b/);
        if (clock) {
            const now = new Date();
            return new Date(
                now.getFullYear(), now.getMonth(), now.getDate(),
                Number(clock[1]), Number(clock[2]), 0, 0
            ).getTime();
        }
        return 0;
    }

    function collectMessages() {
        const messages = [];
        for (const item of findMessageElements()) {
            if (isPinnedRegion(item)) continue;
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
                timeMs: extractMessageTimeMs(item),
                hash
            });
        }
        return messages;
    }

    function takeNewestMessages(items, maxMessages) {
        const limit = Number(maxMessages);
        if (!Number.isFinite(limit) || limit <= 0 || items.length <= limit)
            return items;
        return items.slice(-limit);
    }

    const MAX_IMAGE_TEXT_GAP_MS = 90 * 1000;

    function nearestTextByTime(imageIdx, textIndices, messages) {
        const img = messages[imageIdx];
        let best = -1;
        let bestDt = Infinity;
        let bestDom = Infinity;
        for (const ti of textIndices) {
            const text = messages[ti];
            const dom = Math.abs(imageIdx - ti);
            let dt = Infinity;
            if (img.timeMs && text.timeMs)
                dt = Math.abs(img.timeMs - text.timeMs);
            else
                dt = dom * 60000;
            if (dt < bestDt || (dt === bestDt && dom < bestDom)) {
                bestDt = dt;
                bestDom = dom;
                best = ti;
            }
        }
        if (best < 0) return -1;
        const text = messages[best];
        if (img.timeMs && text.timeMs) {
            if (bestDt > MAX_IMAGE_TEXT_GAP_MS) return -1;
        } else if (bestDom > 2) {
            return -1;
        }
        return best;
    }

    function associateImagesWithText(messages) {
        const textIndices = [];
        for (let i = 0; i < messages.length; i++) {
            if (messages[i].text) textIndices.push(i);
        }

        const imageOwner = new Map();
        let droppedFar = 0;
        for (let i = 0; i < messages.length; i++) {
            const msg = messages[i];
            if (msg.text || !msg.images.length) continue;
            const target = nearestTextByTime(i, textIndices, messages);
            if (target >= 0) imageOwner.set(i, target);
            else droppedFar++;
        }

        const ownedBefore = new Map();
        const ownedAfter = new Map();
        for (const [imgIdx, ti] of imageOwner.entries()) {
            if (imgIdx < ti) {
                if (!ownedBefore.has(ti)) ownedBefore.set(ti, []);
                ownedBefore.get(ti).push(imgIdx);
            } else if (imgIdx > ti) {
                if (!ownedAfter.has(ti)) ownedAfter.set(ti, []);
                ownedAfter.get(ti).push(imgIdx);
            }
        }

        const result = [];
        for (const ti of textIndices) {
            const message = messages[ti];
            const before = ownedBefore.get(ti) || [];
            const after = ownedAfter.get(ti) || [];
            let keep = [];
            if (before.length && after.length) {
                const beforeCount = before.reduce((n, i) => n + messages[i].images.length, 0);
                const afterCount = after.reduce((n, i) => n + messages[i].images.length, 0);
                const beforeDt = minTimeDelta(messages[ti], before, messages);
                const afterDt = minTimeDelta(messages[ti], after, messages);
                if (beforeDt < afterDt) keep = before;
                else if (afterDt < beforeDt) keep = after;
                else keep = beforeCount >= afterCount ? before : after;
            } else {
                keep = before.concat(after);
            }

            const images = [...message.images];
            for (const idx of keep)
                images.push(...messages[idx].images);
            const hash = fnvHash(message.text + images.join('|'));
            const hadBefore = keep.some(idx => idx < ti);
            const hadAfter = keep.some(idx => idx > ti);
            const forward_eligible = images.length > 0
                && (message.images.length > 0 || hadBefore || hadAfter);

            result.push({
                text: message.text,
                images,
                hash,
                message_hash: hash,
                dom_index: ti,
                forward_eligible,
                element: message.element,
                droppedFar
            });
        }
        return result;
    }

    function minTimeDelta(textMsg, indices, messages) {
        if (!textMsg.timeMs) return Infinity;
        let best = Infinity;
        for (const i of indices) {
            if (!messages[i].timeMs) continue;
            best = Math.min(best, Math.abs(messages[i].timeMs - textMsg.timeMs));
        }
        return best;
    }

    async function ensureLazyImagesLoaded() {
        const pane = getMessagePane();
        if (!pane) return;
        const scrollable = pane.closest('[class*="scroll"]') || pane;
        if (!scrollable) return;
        const originalTop = scrollable.scrollTop;
        if (scrollable.scrollHeight > scrollable.clientHeight + 8) {
            scrollable.scrollTop = scrollable.scrollHeight;
            await sleep(400);
            const steps = 5;
            for (let step = steps; step >= 0; step--) {
                scrollable.scrollTop = Math.round(
                    (scrollable.scrollHeight - scrollable.clientHeight) * (step / steps));
                await sleep(200);
            }
        }
        const items = findMessageElements();
        for (let i = items.length - 1; i >= 0 && i >= items.length - 12; i--) {
            try {
                items[i].scrollIntoView({ block: 'center', behavior: 'instant' });
            } catch (_) { /* ignore */ }
            await sleep(160);
        }
        scrollable.scrollTop = originalTop;
        await sleep(300);
    }

    function findPinnedBanner() {
        const nodes = document.querySelectorAll(
            'header, [class*="chat-header"], [class*="header-bar"], [class*="conv-header"]');
        const pinSels = [
            '[class*="pin-msg"]', '[class*="PinMsg"]', '[class*="pinned"]',
            '[class*="pin-bar"]', '[class*="pinBar"]', '[class*="sticky-msg"]',
            '[class*="announc"]'
        ];
        for (const root of nodes) {
            for (const sel of pinSels) {
                const el = root.querySelector(sel);
                const text = normalizeText(el && (el.innerText || el.textContent) || '');
                if (el && text.length > 8)
                    return { el, text };
            }
        }
        for (const root of nodes) {
            for (const el of root.querySelectorAll('div, span, a, p')) {
                const text = normalizeText(el.innerText || el.textContent || '');
                if (!/^tin nhắn\s*:/i.test(text)) continue;
                if (text.length < 16 || text.length > 500) continue;
                return { el, text };
            }
        }
        return null;
    }

    function buildScanResultFromAssociated(messages, maxMessages) {
        const lines = messages.map(m => m.text).filter(Boolean);
        const imageTotal = messages.reduce((sum, m) => sum + m.images.length, 0);
        return {
            group: getConversationTitle(),
            text: lines.join('\n'),
            image_total: imageTotal,
            image_probe: probeMessagePaneImages(),
            messages: messages.map(m => ({
                text: m.text,
                images: m.images,
                hash: m.hash,
                message_hash: m.message_hash || m.hash,
                forward_eligible: !!m.forward_eligible
            })),
            message_count: messages.length,
            max_messages: Number(maxMessages) > 0 ? Number(maxMessages) : 0,
            dom: lastDomDiagnostics
        };
    }

    function buildScanResult(collected, maxMessages) {
        const associated = associateImagesWithText(collected);
        const messages = takeNewestMessages(associated, maxMessages);
        return buildScanResultFromAssociated(messages, maxMessages);
    }

    async function scanConversationAsync(maxMessages) {
        const limit = Number(maxMessages) > 0 ? Number(maxMessages) : 20;
        let collected = collectMessages();
        if (!collected.length) {
            await ensureLazyImagesLoaded();
            collected = collectMessages();
        }
        const associated = associateImagesWithText(collected);
        const scanResult = buildScanResultFromAssociated(
            takeNewestMessages(associated, limit), limit);
        const pin = findPinnedBanner();
        // #region agent log
        fetch('http://127.0.0.1:7563/ingest/62f52916-fbcd-44d7-9d57-b29d0026eaef',{method:'POST',headers:{'Content-Type':'application/json','X-Debug-Session-Id':'36826f'},body:JSON.stringify({sessionId:'36826f',runId:'post-fix',hypothesisId:'H12',location:'user.js:scanConversationAsync',message:'scan_result',data:{title:scanResult.group,maxMessages:limit,collected:collected.length,imageOnly:collected.filter(m=>!m.text&&m.images.length).length,returned:scanResult.message_count,imageTotal:scanResult.image_total,droppedFar:associated[0]&&associated[0].droppedFar||0,pinFound:pin?1:0,perMsg:associated.slice(-6).map(m=>({imgs:m.images.length,tlen:(m.text||'').length}))},timestamp:Date.now()})}).catch(()=>{});
        // #endregion
        return scanResult;
    }

    function scanConversation(maxMessages) {
        const limit = Number(maxMessages) > 0 ? Number(maxMessages) : 20;
        return buildScanResult(collectMessages(), limit);
    }

    function probeSidebarSearch() {
        const vw = window.innerWidth || document.documentElement.clientWidth || 1200;
        const maxRight = vw * 0.52;
        const found = findSidebarSearchInput();
        const candidates = [];
        for (const el of document.querySelectorAll(
            'input, [contenteditable="true"], textarea')) {
            if (isSidebarSearchExcluded(el)) continue;
            const rect = el.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0 || rect.right > maxRight) continue;
            candidates.push({
                tag: el.tagName,
                placeholder: (el.getAttribute('placeholder') || '').slice(0, 60),
                ariaLabel: (el.getAttribute('aria-label') || '').slice(0, 60),
                top: Math.round(rect.top),
                right: Math.round(rect.right)
            });
            if (candidates.length >= 8) break;
        }
        return {
            found: !!found,
            tag: found ? found.tagName : '',
            placeholder: found ? (found.getAttribute('placeholder') || '') : '',
            candidates
        };
    }

    function dumpDom() {
        const messages = collectMessages();
        return {
            role: BRIDGE.role,
            group: getConversationTitle(),
            matchedSelector: lastDomDiagnostics.matchedSelector,
            messageCount: messages.length,
            imageProbe: probeMessagePaneImages(),
            sampleTexts: messages.slice(-5).map(m => ({
                text: m.text.slice(0, 120),
                imageCount: m.images.length
            })),
            search: probeSidebarSearch()
        };
    }

    function findUnreadGroups(knownGroups = []) {
        const items = [];
        for (const sel of SELECTORS.sidebarItem) {
            document.querySelectorAll(sel).forEach(el => items.push(el));
        }
        const unread = [];
        const seen = new Set();
        let badgeCandidates = 0;
        for (const item of items) {
            const nameEl = item.querySelector('[class*="title"], [class*="name"]') || item;
            const name = normalizeText(nameEl.innerText || nameEl.textContent);
            if (!name || seen.has(name)) continue;
            seen.add(name);
            const badge = qs(SELECTORS.unreadBadge, item);
            const badgeText = badge ? normalizeText(badge.innerText || badge.textContent) : '';
            if (badge) badgeCandidates++;
            const numericBadge = /^\d{1,3}$/.test(badgeText);
            const hasUnread = badge && (
                numericBadge ||
                /tin nhắn mới|chưa đọc|unread/i.test(badgeText)
            );
            if (hasUnread) unread.push({
                name,
                count: numericBadge ? Math.max(1, Number.parseInt(badgeText, 10)) : 1
            });
        }
        const knownKeys = new Set(
            knownGroups.map(name => normalizeText(name).toLocaleLowerCase('vi'))
        );
        const visibleKnown = [...seen].filter(name =>
            knownKeys.has(normalizeText(name).toLocaleLowerCase('vi'))
        ).length;
        const diagnostics = {
            sidebarItems: items.length,
            uniqueNames: seen.size,
            badgeCandidates,
            unreadCount: unread.length,
            knownCount: knownKeys.size,
            visibleKnown
        };
        // #region agent log
        fetch('http://127.0.0.1:7563/ingest/62f52916-fbcd-44d7-9d57-b29d0026eaef',{method:'POST',headers:{'Content-Type':'application/json','X-Debug-Session-Id':'93807a'},body:JSON.stringify({sessionId:'93807a',runId:'pre-fix',hypothesisId:'H25,H27',location:'user.js:findUnreadGroups',message:'sidebar_unread_detected',data:diagnostics,timestamp:Date.now()})}).catch(()=>{});
        // #endregion
        return { items: unread, diagnostics };
    }

    async function focusCompose() {
        const box = qs(SELECTORS.composeBox);
        if (!box) throw new Error('Không tìm thấy ô soạn tin Zalo Web.');
        box.focus();
        box.click();
        await sleep(120);
        return true;
    }

    function isMediaHit(el) {
        if (!el) return false;
        return !!(el.closest
            && el.closest('img, video, picture, canvas, a[href], [class*="photo"], [class*="image"], [class*="album"], [class*="media"], [class*="viewer"]'));
    }

    async function focusMessagePane() {
        // Close an image lightbox if a previous click opened one.
        dismissBrowserUi();
        const header = qs([
            '[class*="chat-header"]',
            '[class*="header-chat"]',
            '[class*="conv-header"]'
        ]);
        const title = qs(SELECTORS.conversationTitle);
        const pane = getMessagePane();
        const safe = header || title;
        let via = 'none';
        if (safe) {
            via = header ? 'header' : 'title';
            try { safe.focus({ preventScroll: true }); } catch (_) {
                try { safe.focus(); } catch (__) { /* ignore */ }
            }
            const hit = safe;
            if (!isMediaHit(hit))
                hit.click();
            else
                via += '_media_skip';
        } else if (pane && pane !== document.body) {
            via = 'pane';
            try { pane.focus({ preventScroll: true }); } catch (_) {
                try { pane.focus(); } catch (__) { /* ignore */ }
            }
            const rect = pane.getBoundingClientRect();
            const x = rect.left + Math.min(36, Math.max(8, rect.width * 0.08));
            const y = rect.top + 10;
            const hit = document.elementFromPoint(x, y);
            if (hit && !isMediaHit(hit) && pane.contains(hit))
                hit.click();
            else if (hit && isMediaHit(hit))
                via = 'pane_media_blocked';
        }
        await sleep(80);
        dismissBrowserUi();
        // #region agent log
        fetch('http://127.0.0.1:7563/ingest/62f52916-fbcd-44d7-9d57-b29d0026eaef',{method:'POST',headers:{'Content-Type':'application/json','X-Debug-Session-Id':'36826f'},body:JSON.stringify({sessionId:'36826f',runId:'pre-fix',hypothesisId:'H4',location:'user.js:focusMessagePane',message:'focus_pane',data:{via,title:getConversationTitle(),hasHeader:!!header,hasPane:!!pane},timestamp:Date.now()})}).catch(()=>{});
        // #endregion
        return { ok: true, via };
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

    function isSidebarSearchExcluded(el) {
        if (!el) return true;
        if (el.closest('[class*="chat-input"]') || el.closest('[class*="compose"]')) return true;
        const pane = getMessagePane();
        if (pane && pane !== document.body && pane.contains(el)) return true;
        if (el.closest(SELECTORS.composeBox[0])) return true;
        return false;
    }

    function findSidebarSearchInput() {
        const vw = window.innerWidth || document.documentElement.clientWidth || 1200;
        const maxRight = vw * 0.52;

        for (const sel of SELECTORS.sidebarSearch) {
            for (const el of document.querySelectorAll(sel)) {
                if (isSidebarSearchExcluded(el)) continue;
                const rect = el.getBoundingClientRect();
                if (rect.width <= 0 || rect.height <= 0) continue;
                if (rect.right <= maxRight) return el;
            }
        }

        for (const el of document.querySelectorAll(
            'input[type="text"], input[type="search"], input:not([type]), [contenteditable="true"]')) {
            if (isSidebarSearchExcluded(el)) continue;
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
            // Search results can be anchors with target=_blank. Force this
            // bot-owned navigation to stay in the current Zalo tab.
            const anchor = entry.item.matches?.('a[href]')
                ? entry.item
                : entry.item.querySelector?.('a[href]');
            const previousTarget = anchor ? anchor.getAttribute('target') : null;
            if (anchor) anchor.setAttribute('target', '_self');
            entry.item.click();
            if (anchor) {
                if (previousTarget === null) anchor.removeAttribute('target');
                else anchor.setAttribute('target', previousTarget);
            }
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
        fetch('http://127.0.0.1:7563/ingest/62f52916-fbcd-44d7-9d57-b29d0026eaef',{method:'POST',headers:{'Content-Type':'application/json','X-Debug-Session-Id':'36826f'},body:JSON.stringify({sessionId:'36826f',runId:'pre-fix',hypothesisId:'H3',location:'user.js:navigateToGroup',message:'nav_start',data:{group:groupName,hasSearch:!!search},timestamp:Date.now()})}).catch(()=>{});
        // #endregion
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

    function findAssociatedMessage(sourceGroup, messageHash, roomCode) {
        const messages = associateImagesWithText(collectMessages());
        if (messageHash) {
            const exact = messages.find(m => m.hash === messageHash || m.message_hash === messageHash);
            if (exact) return exact;
        }
        const needle = (roomCode || '').toLowerCase().trim();
        if (needle) {
            const byCode = messages.find(m => m.text.toLowerCase().includes(needle));
            if (byCode) return byCode;
        }
        return null;
    }

    function clickForwardMenuItem() {
        const items = document.querySelectorAll(
            '[role="menuitem"], [class*="menu"] li, [class*="context-menu"] *,'
            + '[class*="popup"] *, button, div[tabindex="0"]');
        for (const el of items) {
            const label = normalizeText(el.innerText || el.textContent || el.getAttribute('aria-label') || '');
            if (/chuyển tiếp|chuyen tiep|forward/i.test(label)) {
                el.click();
                return true;
            }
        }
        return false;
    }

    async function pickForwardTarget(targetGroup) {
        await sleep(400);
        const search = findSidebarSearchInput()
            || document.querySelector(
                '[class*="forward"] input, [class*="modal"] input, [class*="popup"] input[type="text"]');
        if (!search) throw new Error('Không tìm thấy ô chọn nhóm khi forward.');
        await typeSearchQuery(search, targetGroup);
        await sleep(900);
        const opened = await tryOpenMatchingItem(
            collectGroupLabels(
                [...SELECTORS.searchResultItem, ...SELECTORS.sidebarItem],
                document
            ),
            targetGroup
        );
        if (!opened) {
            search.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
            await sleep(900);
        }
        const sendBtn = [...document.querySelectorAll('button, [role="button"], div[tabindex="0"]')]
            .find(el => /gửi|gui|send|chuyển|chuyen/i.test(
                normalizeText(el.innerText || el.textContent || el.getAttribute('aria-label') || '')));
        if (sendBtn) {
            sendBtn.click();
            await sleep(800);
        }
        const title = getConversationTitle();
        if (!groupNamesMatch(title, targetGroup))
            throw new Error('Forward xong nhưng chưa mở nhóm output: ' + targetGroup);
        return { ok: true, group: title };
    }

    async function forwardMessageElement(element, targetGroup) {
        if (!element) throw new Error('Không có DOM bubble để forward.');
        element.scrollIntoView({ block: 'center' });
        await sleep(250);
        element.dispatchEvent(new MouseEvent('contextmenu', {
            bubbles: true, cancelable: true, button: 2
        }));
        await sleep(350);
        if (!clickForwardMenuItem()) {
            element.click();
            await sleep(150);
            element.dispatchEvent(new MouseEvent('contextmenu', {
                bubbles: true, cancelable: true, button: 2
            }));
            await sleep(350);
            if (!clickForwardMenuItem())
                throw new Error('Không mở được menu Chuyển tiếp trên bubble tin.');
        }
        return pickForwardTarget(targetGroup);
    }

    async function forwardMessageToGroup(sourceGroup, targetGroup, messageHash, roomCode) {
        if (!sourceGroup || !targetGroup)
            throw new Error('Thiếu source_group hoặc target_group khi forward.');
        await navigateToGroup(sourceGroup);
        await sleep(500);
        const match = findAssociatedMessage(sourceGroup, messageHash, roomCode);
        if (!match) throw new Error('Không tìm thấy tin để forward: ' + (messageHash || roomCode || ''));
        if (!match.forward_eligible)
            throw new Error('Tin không có ảnh kề — dùng archive paste thay forward.');
        const result = await forwardMessageElement(match.element, targetGroup);
        return { ok: true, forwarded: 1, group: result.group, message_hash: match.hash };
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

    function imageUrlKind(url) {
        const value = String(url || '').toLowerCase();
        if (value.startsWith('blob:')) return 'blob';
        if (value.startsWith('data:')) return 'data';
        if (value.startsWith('https://')) return 'https';
        if (value.startsWith('http://')) return 'http';
        return 'other';
    }

    async function toClipboardPng(blob) {
        if (String(blob.type || '').toLowerCase() === 'image/png')
            return blob;
        const bitmap = await createImageBitmap(blob);
        const canvas = document.createElement('canvas');
        canvas.width = bitmap.width;
        canvas.height = bitmap.height;
        const context = canvas.getContext('2d');
        if (!context) {
            bitmap.close();
            throw new Error('Không tạo được canvas chuyển ảnh sang PNG.');
        }
        context.drawImage(bitmap, 0, 0);
        bitmap.close();
        const png = await new Promise((resolve, reject) => {
            canvas.toBlob(
                value => value ? resolve(value) : reject(
                    new Error('Không chuyển được ảnh sang PNG.')),
                'image/png'
            );
        });
        return png;
    }

    async function copyImageBlobToClipboard(url) {
        try {
            const blob = await requestImageBlob(url);
            const png = await toClipboardPng(blob);
            await navigator.clipboard.write([
                new ClipboardItem({ 'image/png': png })
            ]);
            // #region agent log
            fetch('http://127.0.0.1:7563/ingest/62f52916-fbcd-44d7-9d57-b29d0026eaef',{method:'POST',headers:{'Content-Type':'application/json','X-Debug-Session-Id':'93807a'},body:JSON.stringify({sessionId:'93807a',runId:'post-fix',hypothesisId:'H5',location:'user.js:copyImageBlobToClipboard',message:'clipboard_png_written',data:{urlKind:imageUrlKind(url),sourceMime:blob.type||'',sourceSize:blob.size,pngSize:png.size},timestamp:Date.now()})}).catch(()=>{});
            // #endregion
            return true;
        } catch (error) {
            // #region agent log
            fetch('http://127.0.0.1:7563/ingest/62f52916-fbcd-44d7-9d57-b29d0026eaef',{method:'POST',headers:{'Content-Type':'application/json','X-Debug-Session-Id':'93807a'},body:JSON.stringify({sessionId:'93807a',runId:'post-fix',hypothesisId:'H5,H6',location:'user.js:copyImageBlobToClipboard',message:'clipboard_image_failed',data:{urlKind:imageUrlKind(url),error:String(error&&error.message||error)},timestamp:Date.now()})}).catch(()=>{});
            // #endregion
            throw error;
        }
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

    async function findImagesNearAnchorDom(anchor, limit = 6) {
        const needle = (anchor || '').toLowerCase().trim();
        if (!needle) return [];
        const items = findMessageElements();
        let anchorIdx = -1;
        for (let i = items.length - 1; i >= 0; i--) {
            if (extractMessageText(items[i]).toLowerCase().includes(needle)) {
                anchorIdx = i;
                break;
            }
        }
        if (anchorIdx < 0) return [];
        const urls = [];
        const seen = new Set();
        const pushAll = (list) => {
            for (const url of list) {
                if (!url || seen.has(url)) continue;
                seen.add(url);
                urls.push(url);
            }
        };
        for (let j = Math.max(0, anchorIdx - 1);
            j <= Math.min(items.length - 1, anchorIdx + 2); j++) {
            try {
                items[j].scrollIntoView({ block: 'center', behavior: 'instant' });
            } catch (_) { /* ignore */ }
            await sleep(180);
            pushAll(extractMessageImages(items[j]));
        }
        return urls.slice(0, limit).map(url => ({ url, text: '' }));
    }

    async function findImagesNearAnchor(anchor, limit = 6, messageHash = '') {
        const messages = associateImagesWithText(collectMessages());
        if (messageHash) {
            const exact = messages.find(m =>
                m.hash === messageHash || m.message_hash === messageHash);
            if (exact && exact.images.length) {
                return exact.images.slice(0, limit).map(url => ({
                    url,
                    text: exact.text
                }));
            }
        }

        const needle = (anchor || '').toLowerCase().trim();
        if (needle) {
            for (let i = messages.length - 1; i >= 0; i--) {
                const msg = messages[i];
                if (msg.text.toLowerCase().includes(needle) && msg.images.length) {
                    return msg.images.slice(0, limit).map(url => ({
                        url,
                        text: msg.text
                    }));
                }
            }
        }
        return findImagesNearAnchorDom(anchor, limit);
    }

    async function listImagesForAnchor(anchor, limit = 6, messageHash = '') {
        const found = await findImagesNearAnchor(anchor, limit, messageHash);
        return { count: found.length, urls: found.map(item => item.url) };
    }

    async function setClipboardImageFromBase64(dataBase64, mime) {
        const value = String(dataBase64 || '').replace(/\s/g, '');
        if (!value) throw new Error('data_base64 rỗng.');
        const binary = atob(value);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        const type = mime || 'image/png';
        const png = await toClipboardPng(new Blob([bytes], { type }));
        await navigator.clipboard.write([
            new ClipboardItem({ 'image/png': png })
        ]);
        return { ok: true, mime: 'image/png', size: png.size };
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
                return await scanConversationAsync(cmd.max_messages);
            case 'probe_images':
                await ensureLazyImagesLoaded();
                return probeMessagePaneImages();
            case 'dump_dom':
                return dumpDom();
            case 'title':
                return { group: getConversationTitle() };
            case 'unread':
                {
                    const unread = findUnreadGroups(cmd.known_groups || []);
                    return {
                        groups: unread.items.map(item => item.name),
                        items: unread.items,
                        diagnostics: unread.diagnostics
                    };
                }
            case 'focus_compose':
                await focusCompose();
                return { ok: true };
            case 'focus_pane':
                return await focusMessagePane();
            case 'forward_message':
                return await forwardMessageToGroup(
                    cmd.source_group, cmd.target_group, cmd.message_hash, cmd.room_code || '');
            case 'find_images':
                if (cmd.anchor) await scrollToAnchor(cmd.anchor);
                return await listImagesForAnchor(
                    cmd.anchor, cmd.limit || 6, cmd.message_hash || '');
            case 'copy_image':
                return await copyImageByUrl(cmd.url);
            case 'set_clipboard_image':
                return await setClipboardImageFromBase64(cmd.data_base64, cmd.mime);
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
