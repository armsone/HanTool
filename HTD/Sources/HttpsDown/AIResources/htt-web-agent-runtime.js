/**
 * HTT Web Page Agent JavaScript Runtime
 * Evaluated in isolated WKContentWorld.defaultClient for trusted DOM observation and atomic action dispatch.
 * Does not mutate page scripts or global storage. Excludes passwords, tokens, cards, and OTP elements.
 */

(function () {
    'use strict';

    if (window.__HTT_WEB_AGENT_RUNTIME__) {
        return;
    }

    const RUNTIME = {};

    function getDocToken() {
        if (!document.__httDocToken) {
            document.__httDocToken = 'doc_' + Math.random().toString(36).substring(2, 10) + '_' + Date.now();
        }
        return document.__httDocToken;
    }

    function isVisible(el) {
        if (!el || el.nodeType !== 1) return false;
        if (el.hasAttribute('hidden') || el.getAttribute('aria-hidden') === 'true') return false;
        const view = (el.ownerDocument && el.ownerDocument.defaultView) || window;
        const s = view.getComputedStyle ? view.getComputedStyle(el) : null;
        if (s && (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0')) return false;
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
    }

    function isSensitiveElement(el) {
        if (!el || el.nodeType !== 1) return false;
        const tag = (el.tagName || '').toUpperCase();
        const type = (el.getAttribute('type') || (el.type || '')).toLowerCase();

        // 1. Tag/Type direct checks
        if (tag === 'INPUT') {
            if (type === 'password' || type === 'hidden') return true;
        }

        // 2. Autocomplete attributes
        const autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase();
        if (autocomplete) {
            if (autocomplete.includes('one-time-code') ||
                autocomplete.includes('current-password') ||
                autocomplete.includes('new-password') ||
                autocomplete.includes('cc-') ||
                autocomplete.includes('transaction-')) {
                return true;
            }
        }

        // 3. Control identity tokens (ID, Name, Placeholder, Aria-label, Title)
        const controlTokens = [
            el.getAttribute('id') || '',
            el.getAttribute('name') || '',
            el.getAttribute('placeholder') || '',
            el.getAttribute('aria-label') || '',
            el.getAttribute('title') || ''
        ].join(' ').toLowerCase();

        // Specific credential / auth tokens: PIN/OTP and sensitive credential fields
        // PIN and OTP are bounded by word boundaries (\bpin\b, \botp\b) so non-credential words (e.g., shopping) do not match
        const sensitiveTokens = /(password|passwd|\bpin\b|\botp\b|cvv|cvc|creditcard|card[-_]?number|card[-_]?exp|cc[-_]|secret|ssn|주민|카드번호|비밀번호|인증번호|보안코드|보안문자|인증코드|원타임)/i;
        if (sensitiveTokens.test(controlTokens)) return true;

        // Bounded credential context for token/auth/code: form control identifier/name/placeholder
        const credContextPattern = /(auth[-_]?key|auth[-_]?token|api[-_]?key|access[-_]?token|verify[-_]?code|verification[-_]?code|sms[-_]?code|pass[-_]?code)/i;
        if (credContextPattern.test(controlTokens)) return true;

        // 4. Korean & contextual labels tied directly to this control
        let labelTexts = '';
        if (el.labels && el.labels.length) {
            for (let i = 0; i < el.labels.length; i++) {
                labelTexts += ' ' + (el.labels[i].textContent || '');
            }
        }
        const labelledBy = el.getAttribute('aria-labelledby');
        if (labelledBy) {
            const doc = el.ownerDocument || document;
            const lblEl = doc.getElementById ? doc.getElementById(labelledBy) : null;
            if (lblEl) labelTexts += ' ' + (lblEl.textContent || '');
        }
        const parentLabel = el.closest ? el.closest('label') : null;
        if (parentLabel) {
            labelTexts += ' ' + (parentLabel.textContent || '');
        }

        if (labelTexts) {
            const labelLower = labelTexts.toLowerCase();
            const labelSensitivePattern = /(비밀번호|패스워드|인증번호|인증코드|보안코드|보안문자|주민등록번호|카드번호|유효기간|cvc|cvv|계좌번호|\bpin\b|\botp\b|보안카드)/i;
            if (labelSensitivePattern.test(labelLower)) return true;
        }

        // 5. Sensitive form / section container check
        const sensitiveSection = el.closest ? el.closest('form, section, fieldset, div[role="form"], [role="dialog"]') : null;
        if (sensitiveSection) {
            const secAttr = [
                sensitiveSection.getAttribute('name') || '',
                sensitiveSection.getAttribute('id') || '',
                sensitiveSection.getAttribute('aria-label') || '',
                sensitiveSection.className || ''
            ].join(' ').toLowerCase();
            if (/(auth|login|signin|payment|checkout|creditcard|\botp\b|password|결제|인증|로그인)/i.test(secAttr)) {
                // Inside sensitive section: check if field looks like credential/key/code
                if (/(code|token|key|cred|pass|auth|\bpin\b|card)/i.test(controlTokens)) {
                    return true;
                }
            }
        }

        return false;
    }

    function isInsideSensitiveContainer(el) {
        if (!el || el.nodeType !== 1) return false;
        const container = el.closest ? el.closest('form, section, fieldset, div[role="form"], [role="dialog"]') : null;
        if (!container) return false;
        const text = [
            container.getAttribute('id') || '',
            container.getAttribute('name') || '',
            container.getAttribute('aria-label') || '',
            container.className || ''
        ].join(' ').toLowerCase();
        return /(auth|login|signin|payment|checkout|creditcard|\botp\b|password|결제|인증|로그인|보안인증)/i.test(text);
    }

    function isSubmitLikeElement(el) {
        if (!el) return false;
        const tag = el.tagName.toUpperCase();

        // 1. Radio and Checkbox are clearly non-submit interactive inputs
        if (tag === 'INPUT') {
            const type = (el.getAttribute('type') || el.type || '').toLowerCase();
            if (type === 'checkbox' || type === 'radio') {
                return false;
            }
            if (type === 'submit' || type === 'image') {
                return true;
            }
        }

        // 2. Safely known non-mutating UI elements
        const role = (el.getAttribute('role') || '').toLowerCase();
        if (role === 'checkbox' || role === 'radio' || role === 'tab' || role === 'combobox' || role === 'searchbox') {
            return false;
        }

        // 3. All generic buttons and links are conservative true (core approval gates them anyway)
        if (tag === 'BUTTON' || tag === 'A' || role === 'button' || role === 'link' || role === 'menuitem') {
            return true;
        }

        // 4. Fallback keyword check for custom interactives
        const text = [
            el.textContent || '',
            el.getAttribute('value') || '',
            el.getAttribute('aria-label') || '',
            el.getAttribute('title') || ''
        ].join(' ').trim().toLowerCase();

        const submitPattern = /(submit|send|pay|purchase|buy|order|checkout|delete|remove|withdraw|confirm|save|결제|구매|주문|삭제|전송|제출|탈퇴|회원가입|확인|저장)/i;
        return submitPattern.test(text);
    }

    function getAccessibleName(el) {
        if (!el || el.nodeType !== 1) return '';
        if (el.getAttribute('aria-label')) {
            return el.getAttribute('aria-label').trim();
        }
        const labelledBy = el.getAttribute('aria-labelledby');
        if (labelledBy) {
            const doc = el.ownerDocument || document;
            const labelEl = doc.getElementById ? doc.getElementById(labelledBy) : null;
            if (labelEl && labelEl.textContent) {
                return labelEl.textContent.trim();
            }
        }
        if ((el.tagName || '').toUpperCase() === 'INPUT') {
            const placeholder = el.getAttribute('placeholder');
            if (placeholder) return placeholder.trim();
            const val = el.value || '';
            if (val && !isSensitiveElement(el)) return val.trim();
        }
        const text = el.innerText || el.textContent || '';
        const clean = text.replace(/\s+/g, ' ').trim();
        if (clean.length > 0) {
            return clean.length > 80 ? clean.substring(0, 77) + '...' : clean;
        }
        return el.getAttribute('title') || el.getAttribute('name') || '';
    }

    // 1. Snapshot Extraction
    RUNTIME.captureSnapshot = function (options) {
        try {
            const opts = options || {};
            const maxChars = opts.maxChars || 16000;
            const maxNodes = opts.maxNodes || 8000;
            const maxInteractives = opts.maxInteractives || 120;

            const docToken = getDocToken();
            document.__httSnapshotSeq = (document.__httSnapshotSeq || 0) + 1;
            const snapshotId = 'snap_' + document.__httSnapshotSeq;

            if (!document.__httElementRegistry) {
                document.__httElementRegistry = {};
            }
            const registry = new Map();
            document.__httElementRegistry[snapshotId] = registry;

            // Clean up older snapshot registries (> 5 old)
            const keys = Object.keys(document.__httElementRegistry);
            if (keys.length > 5) {
                for (let i = 0; i < keys.length - 5; i++) {
                    delete document.__httElementRegistry[keys[i]];
                }
            }

            const title = (document.title || '').trim();
            let truncated = false;
            let totalLen = 0;
            const textChunks = [];

            const root = document.querySelector('article')
                      || document.querySelector('main')
                      || document.querySelector('[role="main"]')
                      || document.body;

            if (!root) {
                return JSON.stringify({ success: false, error: 'NO_READABLE_ROOT' });
            }

            const excludedTextTags = new Set([
                'SCRIPT', 'STYLE', 'NOSCRIPT', 'IFRAME', 'OBJECT', 'EMBED', 'SVG', 'CANVAS', 'DIALOG',
                'TEXTAREA', 'INPUT', 'SELECT', 'OPTION'
            ]);

            // Form container check for notices
            const sensitiveFormOrDialog = document.querySelector('form[action*="login" i], form[action*="auth" i], form[action*="pay" i], [role="dialog"][aria-label*="인증" i], [role="dialog"][aria-label*="auth" i]');
            if (sensitiveFormOrDialog || isInsideSensitiveContainer(document.activeElement)) {
                textChunks.push('[보안 안내: 인증, 결제 또는 민감 정보 입력 화면이 감지되었습니다. 민감한 인증 정보는 수집되지 않으며 필요 시 사용자 직접 입력이 권장됩니다.]');
            }

            let walkedNodes = 0;

            function extractVisibleTextFromRoot(subRoot, ownerDoc, viewportOnly = false, charBudget = maxChars) {
                if (!subRoot || walkedNodes >= maxNodes || truncated) return;
                const doc = ownerDoc || subRoot.ownerDocument || document;
                const textWalker = doc.createTreeWalker(
                    subRoot,
                    NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT,
                    {
                        acceptNode(node) {
                            if (node.nodeType === 1) {
                                const tag = node.tagName.toUpperCase();
                                if (excludedTextTags.has(tag)) return NodeFilter.FILTER_REJECT;
                                if (node.hasAttribute('hidden') || node.getAttribute('aria-hidden') === 'true') return NodeFilter.FILTER_REJECT;
                                if (tag === 'INPUT' && (node.getAttribute('type') || node.type || '').toLowerCase() === 'hidden') {
                                    return NodeFilter.FILTER_REJECT;
                                }
                                if (isSensitiveElement(node)) return NodeFilter.FILTER_REJECT;
                                // Check if this element is a sensitive section or sensitive label
                                if (tag === 'LABEL') {
                                    const targetId = node.getAttribute('for');
                                    const nDoc = node.ownerDocument || doc;
                                    const targetControl = targetId ? (nDoc.getElementById ? nDoc.getElementById(targetId) : null) : (node.querySelector ? node.querySelector('input, select, textarea') : null);
                                    if (targetControl && isSensitiveElement(targetControl)) {
                                        return NodeFilter.FILTER_REJECT;
                                    }
                                    const labelText = (node.textContent || '').toLowerCase();
                                    if (/(비밀번호|패스워드|인증번호|보안코드|보안문자|주민등록번호|카드번호|cvc|cvv|\bpin\b|\botp\b)/i.test(labelText)) {
                                        return NodeFilter.FILTER_REJECT;
                                    }
                                }
                                const view = (node.ownerDocument && node.ownerDocument.defaultView) || window;
                                const s = view.getComputedStyle ? view.getComputedStyle(node) : null;
                                if (s && (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0')) return NodeFilter.FILTER_REJECT;
                                return NodeFilter.FILTER_ACCEPT;
                            } else if (node.nodeType === 3) {
                                if (!node.textContent || !node.textContent.trim()) return NodeFilter.FILTER_REJECT;
                                const parent = node.parentElement;
                                if (parent) {
                                    const parentTag = (parent.tagName || '').toUpperCase();
                                    if (excludedTextTags.has(parentTag)) return NodeFilter.FILTER_REJECT;
                                    if (isSensitiveElement(parent)) return NodeFilter.FILTER_REJECT;
                                    if (parentTag === 'LABEL') {
                                        const targetId = parent.getAttribute('for');
                                        const pDoc = parent.ownerDocument || doc;
                                        const targetControl = targetId ? (pDoc.getElementById ? pDoc.getElementById(targetId) : null) : (parent.querySelector ? parent.querySelector('input, select, textarea') : null);
                                        if (targetControl && isSensitiveElement(targetControl)) {
                                            return NodeFilter.FILTER_REJECT;
                                        }
                                    }
                                }
                                return NodeFilter.FILTER_ACCEPT;
                            }
                            return NodeFilter.FILTER_REJECT;
                        }
                    }
                );

                let currNode = textWalker.nextNode();
                while (currNode && walkedNodes < maxNodes) {
                    walkedNodes++;
                    if (currNode.nodeType === 3 && (!viewportOnly || snapshotTextInViewport(currNode))) {
                        const clean = currNode.textContent.replace(/\s+/g, ' ');
                        if (clean.trim().length > 0) {
                            if (totalLen + clean.length > charBudget) {
                                const remaining = charBudget - totalLen;
                                if (remaining > 0) {
                                    textChunks.push(clean.substring(0, remaining));
                                }
                                truncated = true;
                                break;
                            } else {
                                textChunks.push(clean);
                                totalLen += clean.length;
                            }
                        }
                    }
                    currNode = textWalker.nextNode();
                }
            }

            let viewportUnavailable = false;

            function snapshotRectInViewport(rect, doc) {
                if (!rect || rect.width <= 0 || rect.height <= 0) return false;
                let curDoc = doc || document;
                let curRect = {
                    left: rect.left, top: rect.top,
                    right: rect.right, bottom: rect.bottom,
                    width: rect.width, height: rect.height
                };
                let depth = 0;
                while (curDoc && depth++ < 10) {
                    const win = curDoc.defaultView;
                    const docEl = curDoc.documentElement;
                    const vw = (win && Number.isFinite(win.innerWidth) && win.innerWidth > 0) ? win.innerWidth :
                               (docEl && Number.isFinite(docEl.clientWidth) && docEl.clientWidth > 0) ? docEl.clientWidth : 0;
                    const vh = (win && Number.isFinite(win.innerHeight) && win.innerHeight > 0) ? win.innerHeight :
                               (docEl && Number.isFinite(docEl.clientHeight) && docEl.clientHeight > 0) ? docEl.clientHeight : 0;

                    if (vw <= 0 || vh <= 0) {
                        viewportUnavailable = true;
                        return true;
                    }

                    const interLeft = Math.max(curRect.left, 0);
                    const interTop = Math.max(curRect.top, 0);
                    const interRight = Math.min(curRect.right, vw);
                    const interBottom = Math.min(curRect.bottom, vh);

                    if (interRight <= interLeft || interBottom <= interTop) return false;

                    curRect = {
                        left: interLeft, top: interTop,
                        right: interRight, bottom: interBottom,
                        width: interRight - interLeft, height: interBottom - interTop
                    };

                    let frameEl = null;
                    try {
                        frameEl = curDoc.defaultView && curDoc.defaultView.frameElement;
                    } catch (e) {
                        viewportUnavailable = true;
                        return true;
                    }
                    if (!frameEl) break;
                    if (!isVisible(frameEl)) return false;

                    const fRect = frameEl.getBoundingClientRect();
                    const clientLeft = frameEl.clientLeft || 0;
                    const clientTop = frameEl.clientTop || 0;
                    const scaleX = (frameEl.offsetWidth > 0 && fRect.width > 0) ? (fRect.width / frameEl.offsetWidth) : 1;
                    const scaleY = (frameEl.offsetHeight > 0 && fRect.height > 0) ? (fRect.height / frameEl.offsetHeight) : 1;

                    curRect = {
                        left: fRect.left + clientLeft + curRect.left * scaleX,
                        top: fRect.top + clientTop + curRect.top * scaleY,
                        right: fRect.left + clientLeft + curRect.right * scaleX,
                        bottom: fRect.top + clientTop + curRect.bottom * scaleY,
                        width: curRect.width * scaleX,
                        height: curRect.height * scaleY
                    };
                    curDoc = frameEl.ownerDocument;
                }
                return true;
            }

            function snapshotElementInViewport(el) {
                if (!isVisible(el)) return false;
                return snapshotRectInViewport(el.getBoundingClientRect(), el.ownerDocument);
            }

            function snapshotTextInViewport(node) {
                const ownerDoc = node.ownerDocument || document;
                try {
                    const range = ownerDoc.createRange();
                    range.selectNodeContents(node);
                    const rects = range.getClientRects();
                    if (!rects || rects.length === 0) {
                        return snapshotRectInViewport(range.getBoundingClientRect(), ownerDoc);
                    }
                    for (let i = 0; i < rects.length; i++) {
                        if (snapshotRectInViewport(rects[i], ownerDoc)) return true;
                    }
                    return false;
                } catch (e) {
                    return true;
                }
            }

            // Viewport-only text extraction pass (budget <= 4000)
            const initialNotice = textChunks.join(' ').trim();
            textChunks.length = 0;
            totalLen = 0;
            walkedNodes = 0;
            truncated = false;

            const vpBudget = Math.min(4000, Math.max(0, maxChars - initialNotice.length - 100));
            if (document.body) {
                extractVisibleTextFromRoot(document.body, document, true, vpBudget);
            }
            const vpIframes = document.querySelectorAll('iframe');
            for (let i = 0; i < vpIframes.length && totalLen < vpBudget; i++) {
                    if (walkedNodes >= maxNodes || truncated) break;
                try {
                    const iframe = vpIframes[i];
                    if (!isVisible(iframe) || !snapshotElementInViewport(iframe)) continue;
                    const iframeDoc = iframe.contentDocument || (iframe.contentWindow && iframe.contentWindow.document);
                    if (!iframeDoc || !iframeDoc.body) continue;
                    extractVisibleTextFromRoot(iframeDoc.body, iframeDoc, true, vpBudget);
                } catch (e) {}
            }
            const viewportText = textChunks.join(' ').replace(/\s+/g, ' ').trim();
            const viewportTruncated = truncated;

            // Reset counters and arrays for whole-page research pass
            textChunks.length = 0;
            totalLen = 0;
            walkedNodes = 0;
            truncated = false;

            const vpHeading = viewportUnavailable ? '[현재 화면 크기 확인 불가: CSS 표시 기준]' : '[현재 화면]';
            const fullHeading = '[페이지 전체·연구용]';
            const reservedHeadingChars = vpHeading.length + fullHeading.length + 10;
            const wholeBudget = Math.max(0, maxChars - (viewportText ? viewportText.length : 0) - initialNotice.length - reservedHeadingChars);

            // Walk root DOM for text extraction (whole page)
            extractVisibleTextFromRoot(root, document, false, wholeBudget);

            // Bounded same-origin iframe visible text extraction
            try {
                const iframesForText = Array.from(document.querySelectorAll('iframe'));
                for (const iframe of iframesForText) {
                    if (walkedNodes >= maxNodes || truncated) break;
                    if (!isVisible(iframe)) continue;
                    try {
                        const iframeDoc = iframe.contentDocument || (iframe.contentWindow && iframe.contentWindow.document);
                        if (iframeDoc) {
                            const iframeRoot = iframeDoc.querySelector('article')
                                            || iframeDoc.querySelector('main')
                                            || iframeDoc.querySelector('[role="main"]')
                                            || iframeDoc.body;
                            if (iframeRoot) {
                                extractVisibleTextFromRoot(iframeRoot, iframeDoc, false, wholeBudget);
                            }
                        }
                    } catch (_) {
                        // Cross-origin iframe security error ignored
                    }
                }
            } catch (_) {}

            const rawFullText = textChunks.join(' ').replace(/\s+/g, ' ').trim();
            const fullTruncated = truncated;

            const composedParts = [];
            if (initialNotice) composedParts.push(initialNotice);
            if (viewportText) composedParts.push(vpHeading + '\n' + viewportText);
            if (rawFullText) composedParts.push(fullHeading + '\n' + rawFullText);

            let composedText = composedParts.join('\n\n').trim();
            const composeOverflow = composedText.length > maxChars;
            const pageText = composeOverflow ? composedText.slice(0, maxChars) : composedText;
            truncated = viewportTruncated || fullTruncated || composeOverflow;

            // 2. Collect interactive elements
            const interactives = [];
            let refCounter = 0;

            function computeFingerprint(el, role, name, href) {
                const tag = (el.tagName || '').toUpperCase();
                const type = (el.getAttribute('type') || el.type || '').toLowerCase();
                const id = el.getAttribute('id') || '';
                const elName = el.getAttribute('name') || '';
                const formAction = el.getAttribute('formaction') || (el.formAction || '');
                const isSubmit = isSubmitLikeElement(el);

                return {
                    tag: tag,
                    type: type,
                    role: role || '',
                    name: name || '',
                    id: id,
                    elementName: elName,
                    href: href || '',
                    formAction: formAction,
                    isSubmitLike: isSubmit,
                    ownerDoc: el.ownerDocument
                };
            }

            function processInteractiveElement(el, prefix, frameDoc, frameEl) {
                if (!isVisible(el)) return;
                if (!snapshotElementInViewport(el)) return;
                if (frameEl && !snapshotElementInViewport(frameEl)) return;
                if (isSensitiveElement(el)) return; // Exclude sensitive/credential elements completely

                const tag = el.tagName.toUpperCase();
                let role = '';
                let isInteractive = false;

                if (tag === 'A' && el.hasAttribute('href')) {
                    role = 'link';
                    isInteractive = true;
                } else if (tag === 'BUTTON') {
                    role = 'button';
                    isInteractive = true;
                } else if (tag === 'INPUT') {
                    const type = (el.type || 'text').toLowerCase();
                    if (type === 'submit' || type === 'button' || type === 'reset') {
                        role = 'button';
                        isInteractive = true;
                    } else if (type === 'checkbox') {
                        role = 'checkbox';
                        isInteractive = true;
                    } else if (type === 'radio') {
                        role = 'radio';
                        isInteractive = true;
                    } else if (!['hidden', 'password'].includes(type)) {
                        role = 'input';
                        isInteractive = true;
                    }
                } else if (tag === 'SELECT') {
                    role = 'select';
                    isInteractive = true;
                } else if (tag === 'TEXTAREA') {
                    role = 'textarea';
                    isInteractive = true;
                } else if (el.isContentEditable || el.getAttribute('contenteditable') === 'true') {
                    role = 'textbox';
                    isInteractive = true;
                } else {
                    const explicitRole = (el.getAttribute('role') || '').toLowerCase();
                    if (['button', 'link', 'checkbox', 'radio', 'combobox', 'tab', 'menuitem', 'searchbox', 'textbox'].includes(explicitRole)) {
                        role = explicitRole;
                        isInteractive = true;
                    } else if (el.hasAttribute('onclick') || el.getAttribute('tabindex') === '0') {
                        role = 'button';
                        isInteractive = true;
                    }
                }

                if (!isInteractive) return;

                refCounter++;
                const ref = (prefix || '') + 'el_' + refCounter;
                const name = getAccessibleName(el);
                const disabled = !!el.disabled || el.getAttribute('aria-disabled') === 'true';
                const isSubmit = isSubmitLikeElement(el);

                let state = '';
                if (disabled) state += 'disabled ';
                if (el.checked || el.getAttribute('aria-checked') === 'true') state += 'checked ';
                if (el.getAttribute('aria-expanded') === 'true') state += 'expanded ';

                let val = '';
                if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
                    if (!isSensitiveElement(el)) {
                        val = (el.value || '').substring(0, 80);
                    }
                }

                const href = (tag === 'A' && el.href) ? el.href : '';
                const fingerprint = computeFingerprint(el, role, name, href);

                registry.set(ref, {
                    element: el,
                    fingerprint: fingerprint,
                    expectedDoc: frameDoc || document,
                    frameElement: frameEl || null
                });

                let displayName = name;
                if (!displayName && tag === 'A' && el.getAttribute('href')) {
                    try {
                        const imgs = el.querySelectorAll('img[alt]');
                        for (let i = 0; i < imgs.length && i < 8; i++) {
                            const img = imgs[i];
                            const alt = (img.getAttribute('alt') || '').replace(/\s+/g, ' ').trim();
                            if (alt && isVisible(img)) {
                                displayName = alt.length > 80 ? alt.slice(0, 77) + '...' : alt;
                                break;
                            }
                        }
                        if (!displayName) {
                            const href = el.getAttribute('href') || '';
                            const parsed = new URL(href, window.location.href);
                            if (parsed.protocol === 'http:' || parsed.protocol === 'https:') {
                                const rawUrl = parsed.origin + parsed.pathname;
                                displayName = rawUrl.length > 80 ? rawUrl.slice(0, 77) + '...' : rawUrl;
                            }
                        }
                    } catch (e) {}
                }

                if (el.closest('article') && (tag === 'A' || tag === 'BUTTON' || role === 'link' || role === 'button')) {
                    try {
                        const article = el.closest('article');
                        let headerLabel = '';
                        const headerLink = article.querySelector('header a[href]');
                        if (headerLink && !isSensitiveElement(headerLink)) {
                            headerLabel = (getAccessibleName(headerLink) || '').replace(/\s+/g, ' ').trim();
                            if (!headerLabel) {
                                try {
                                    const p = new URL(headerLink.getAttribute('href') || '', headerLink.ownerDocument.baseURI);
                                    headerLabel = p.pathname.replace(/\s+/g, ' ').trim();
                                } catch (e) {}
                            }
                        }
                        let permalink = '';
                        const candidateLinks = article.querySelectorAll('a[href]');
                        for (let i = 0; i < candidateLinks.length && i < 32; i++) {
                            const a = candidateLinks[i];
                            if (isSensitiveElement(a)) continue;
                            try {
                                const u = new URL(a.getAttribute('href') || '', a.ownerDocument.baseURI);
                                if (u.protocol === 'http:' || u.protocol === 'https:') {
                                    const rel = a.getAttribute('rel') || '';
                                    const hasTime = !!a.querySelector('time');
                                    const pathMatches = /^\/(p|reel|reels)\/[^/]+\//.test(u.pathname);
                                    if (rel.includes('bookmark') || hasTime || pathMatches) {
                                        permalink = u.origin + u.pathname;
                                        break;
                                    }
                                }
                            } catch (e) {}
                        }
                        const parts = [headerLabel, permalink].filter(Boolean);
                        if (parts.length > 0) {
                            let ctx = parts.join(' ').replace(/\s+/g, ' ').trim();
                            if (ctx.length > 120) {
                                ctx = ctx.slice(0, 117) + '...';
                            }
                            displayName = displayName ? `${displayName} [게시물: ${ctx}]` : `[게시물: ${ctx}]`;
                        }
                    } catch (e) {}
                }

                try {
                    const _docLoc = (el.ownerDocument && el.ownerDocument.location) || (typeof window !== 'undefined' ? window.location : null);
                    const _host = (_docLoc && _docLoc.hostname ? _docLoc.hostname : '').toLowerCase();
                    if (_host === 'instagram.com' || _host === 'www.instagram.com') {
                        const _normName = ((name || (el.querySelector('svg')?.getAttribute('aria-label')) || '')).replace(/\s+/g, ' ').trim().toLowerCase();
                        if (_normName === '좋아요' || _normName === '좋아요 취소' || _normName === 'like' || _normName === 'unlike') {
                            if (tag === 'BUTTON' || tag === 'A' || role === 'button' || role === 'link') {
                                const _svgs = el.querySelectorAll('svg');
                                let _ownW = 0;
                                for (let _s = 0; _s < _svgs.length; _s++) {
                                    const _svg = _svgs[_s];
                                    if (typeof isVisible === 'function' ? isVisible(_svg) : true) {
                                        const _r = _svg.getBoundingClientRect();
                                        if (_r && Number.isFinite(_r.width) && _r.width > 0 && _r.width <= 20) {
                                            _ownW = _r.width;
                                            break;
                                        }
                                    }
                                }
                                if (_ownW > 0) {
                                    const _art = el.closest('article') || ((typeof _docLoc !== 'undefined' && _docLoc && /^\/p\/[A-Za-z0-9_-]+\/?$/.test(_docLoc.pathname)) ? el.closest('main') : null);
                                    if (_art) {
                                        const _cands = _art.querySelectorAll('button,a[href],[role="button"],[role="link"]');
                                        const _lim = Math.min(_cands.length, 80);
                                        let _maxW = 0;
                                        for (let _i = 0; _i < _lim; _i++) {
                                            const _c = _cands[_i];
                                            const _cName = ((typeof getAccessibleName === 'function' ? getAccessibleName(_c) : '') || (_c.querySelector('svg')?.getAttribute('aria-label')) || '').replace(/\s+/g, ' ').trim().toLowerCase();
                                            if (_cName === '좋아요' || _cName === '좋아요 취소' || _cName === 'like' || _cName === 'unlike') {
                                                const _cSvgs = _c.querySelectorAll('svg');
                                                for (let _j = 0; _j < _cSvgs.length; _j++) {
                                                    const _csv = _cSvgs[_j];
                                                    if (typeof isVisible === 'function' ? isVisible(_csv) : true) {
                                                        const _cr = _csv.getBoundingClientRect();
                                                        if (_cr && Number.isFinite(_cr.width) && _cr.width > _maxW) {
                                                            _maxW = _cr.width;
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        if (_maxW >= _ownW * 1.25 && _maxW > 20) {
                                            displayName = (displayName || '') + ' [댓글 반응]';
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch (_e) {}
                const interactiveType = tag === 'INPUT' ? (el.type || el.getAttribute('type') || 'input').toLowerCase() : tag.toLowerCase();

                interactives.push({
                    ref: ref,
                    role: role,
                    name: displayName,
                    state: state.trim(),
                    type: interactiveType,
                    value: val,
                    isSubmitLike: isSubmit
                });
            }

            // Query interactive candidates
            const interactiveSelector = 'a[href], button, input, select, textarea, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="combobox"], [role="tab"], [role="menuitem"], [contenteditable="true"]';
            const candidates = Array.from(document.querySelectorAll(interactiveSelector));

            for (const el of candidates) {
                if (interactives.length >= maxInteractives) break;
                processInteractiveElement(el, '', document, null);
            }

            // Also check same-origin iframes
            try {
                const iframes = Array.from(document.querySelectorAll('iframe'));
                let frameIndex = 0;
                for (const iframe of iframes) {
                    if (interactives.length >= maxInteractives) break;
                    if (!isVisible(iframe) || !snapshotElementInViewport(iframe)) continue;
                    try {
                        const iframeDoc = iframe.contentDocument || (iframe.contentWindow && iframe.contentWindow.document);
                        if (iframeDoc) {
                            frameIndex++;
                            const iframeCandidates = Array.from(iframeDoc.querySelectorAll(interactiveSelector));
                            for (const el of iframeCandidates) {
                                if (interactives.length >= maxInteractives) break;
                                processInteractiveElement(el, 'f' + frameIndex + '_', iframeDoc, iframe);
                            }
                        }
                    } catch (_) {
                        // Cross-origin iframe security error ignored
                    }
                }
            } catch (_) {}

            let postEvidence = null;
            try {
                const currentHref = window.location.href || "";
                const currentHost = (window.location.hostname || "").toLowerCase();
                if (currentHost === "instagram.com" || currentHost === "www.instagram.com") {
                    const currentPath = window.location.pathname || "";
                    const postMatch = currentPath.match(/^\/(p|reel|reels)\/([A-Za-z0-9_-]+)\/?$/);
                    if (postMatch) {
                        const matchedType = postMatch[1];
                        const shortcode = postMatch[2];
                        const canonicalURL = `https://www.instagram.com/${matchedType}/${shortcode}/`;

                        const articles = Array.from(document.querySelectorAll("article"));
                        const visibleArticles = articles.filter(el => {
                            try {
                                return (typeof isVisible === "function" ? isVisible(el) : true) &&
                                       (typeof snapshotElementInViewport === "function" ? snapshotElementInViewport(el) : true);
                            } catch (_) {
                                return false;
                            }
                        });

                        if (visibleArticles.length === 1) {
                            const article = visibleArticles[0];
                            let author = "";
let headerAnchorList = Array.from(article.querySelectorAll("header a[href]"));
if (headerAnchorList.length === 0) {
  const h1 = article.querySelector("h1");
  const li = h1 ? h1.closest("li") : null;
  if (li) {
    headerAnchorList = Array.from(li.querySelectorAll("a[href]"));
  }
}
                            const candidateUsernames = new Set();
                            const reservedPaths = new Set(["explore", "p", "reel", "reels", "accounts", "direct", "stories", "developer", "about", "legal", "privacy"]);

                            for (const a of headerAnchorList) {
                                const href = a.getAttribute("href") || "";
                                const match = href.match(/^\/([A-Za-z0-9._]+)\/?$/);
                                if (match) {
                                    const uname = match[1].toLowerCase();
                                    if (!reservedPaths.has(uname)) {
                                        candidateUsernames.add(uname);
                                    }
                                }
                            }
                            if (candidateUsernames.size === 1) {
                                author = Array.from(candidateUsernames)[0].substring(0, 100);
                            }

                            let publishedAt = "";
                            const timeElements = Array.from(article.querySelectorAll("time[datetime]"));
                            const validDateStrings = new Set();
                            const currentShortcode = shortcode;
                            const postTimeElements = currentShortcode ? timeElements.filter(t => {
                                const anchor = t.closest("a[href]");
                                if (!anchor) return false;
                                try {
                                    const parsedURL = new URL(anchor.href, window.location.origin);
                                    const host = parsedURL.hostname.toLowerCase();
                                    if (host !== "instagram.com" && host !== "www.instagram.com") return false;
                                    const m = parsedURL.pathname.match(/^\/(?:p|reel|reels)\/([A-Za-z0-9_-]+)\/?$/);
                                    return m && m[1] === currentShortcode;
                                } catch (e) {
                                    return false;
                                }
                            }) : [];
                            const targetTimes = postTimeElements.length > 0 ? postTimeElements : (timeElements.length === 1 ? timeElements : []);
                            for (const t of targetTimes) {
                                const dtStr = (t.getAttribute("datetime") || "").trim();
                                if (dtStr) {
                                    const parsed = Date.parse(dtStr);
                                    if (!isNaN(parsed) && parsed > 0 && parsed <= Date.now() + 86400000) {
                                        validDateStrings.add(dtStr.substring(0, 100));
                                    }
                                }
                            }
                            if (validDateStrings.size === 1) {
                                publishedAt = Array.from(validDateStrings)[0];
                            }

                            let caption = "";
                            const h1 = article.querySelector("h1");
                            if (h1) {
                                const isH1Visible = typeof isVisible === "function" ? isVisible(h1) : true;
                                if (isH1Visible) {
                                    caption = (h1.innerText || h1.textContent || "").trim().substring(0, 8000);
                                }
                            }

                            postEvidence = {
                                shortcode: shortcode.substring(0, 100),
                                canonicalURL: canonicalURL.substring(0, 2048),
                                author: author,
                                publishedAt: publishedAt,
                                caption: caption
                            };
                        }
                    }
                }
            } catch (_) {
                postEvidence = null;
            }

            return JSON.stringify({
                success: true,
                documentToken: docToken,
                snapshotId: snapshotId,
                url: window.location.href,
                title: title,
                text: pageText,
                isTruncated: truncated,
                interactives: interactives,
                postEvidence: postEvidence
            });
        } catch (e) {
            return JSON.stringify({ success: false, error: '스냅샷 생성 중 오류: ' + (e && e.message ? e.message : String(e)) });
        }
    };

    // 2. Action Execution
    RUNTIME.executeAction = function (payload) {
        try {
            if (!payload || typeof payload !== 'object') {
                return JSON.stringify({ success: false, error: '유효하지 않은 요청 데이터입니다.' });
            }

            const currentDocToken = getDocToken();
            if (payload.documentToken && payload.documentToken !== currentDocToken) {
                return JSON.stringify({ success: false, error: 'DOC_TOKEN_MISMATCH', details: '페이지가 새로고침되었거나 이동하여 이전 동작이 취소되었습니다.' });
            }

            const action = payload.action || {};
            const actionType = (action.type || '').toLowerCase();
            const snapshotId = payload.snapshotId;

            if (actionType === 'scroll') {
                const deltaY = typeof action.amount === 'number' && Number.isFinite(action.amount)
                    ? Math.max(-2000, Math.min(2000, action.amount))
                    : (action.direction === 'up' ? -400 : 400);
                window.scrollBy({ top: deltaY, behavior: 'smooth' });
                return JSON.stringify({ success: true, performed: 'scroll', deltaY: deltaY });
            }

            if (actionType === 'read') {
                return JSON.stringify({ success: true, performed: 'read' });
            }

            const ref = action.ref;
            if (!ref || typeof ref !== 'string') {
                return JSON.stringify({ success: false, error: 'TARGET_REF_REQUIRED', details: '동작 대상 요소의 ref가 누락되었거나 유효하지 않습니다.' });
            }

            const registry = document.__httElementRegistry && document.__httElementRegistry[snapshotId];
            if (!registry) {
                return JSON.stringify({ success: false, error: 'SNAPSHOT_STALE', details: '스냅샷 식별자가 유효하지 않거나 만료되었습니다.' });
            }

            const regEntry = registry.get(ref);
            if (!regEntry) {
                return JSON.stringify({ success: false, error: 'ELEMENT_NOT_FOUND', details: '스냅샷 레지스트리에 해당 ref가 없습니다.' });
            }

            const el = regEntry.element || regEntry;
            const expectedFp = regEntry.fingerprint;
            const expectedDoc = regEntry.expectedDoc;
            const frameEl = regEntry.frameElement;

            // Check document identity for same-origin iframes and replaced documents
            if (expectedDoc && el.ownerDocument !== expectedDoc) {
                return JSON.stringify({ success: false, error: 'DOCUMENT_IDENTITY_CHANGED', details: '프레임 또는 소유 문서가 교체되었습니다.' });
            }

            // If the element belongs to an iframe, validate that frameElement.contentDocument is still the expectedDoc
            if (frameEl) {
                let actualFrameDoc = null;
                try {
                    actualFrameDoc = frameEl.contentDocument || (frameEl.contentWindow && frameEl.contentWindow.document);
                } catch (_) {}
                if (!actualFrameDoc || actualFrameDoc !== expectedDoc) {
                    return JSON.stringify({ success: false, error: 'DOCUMENT_IDENTITY_CHANGED', details: '아이프레임이 새로고침되었거나 프레임 문서가 일치하지 않습니다.' });
                }
            }

            if (!el || !el.isConnected) {
                return JSON.stringify({ success: false, error: 'ELEMENT_DISCONNECTED', details: '대상 요소가 화면에서 사라졌거나 DOM이 변경되었습니다.' });
            }

            if (!isVisible(el)) {
                return JSON.stringify({ success: false, error: 'ELEMENT_NOT_VISIBLE', details: '대상 요소가 화면에 보이지 않습니다.' });
            }

            if (el.disabled || el.getAttribute('aria-disabled') === 'true') {
                return JSON.stringify({ success: false, error: 'ELEMENT_DISABLED', details: '대상 요소가 비활성화 상태입니다.' });
            }

            if (isSensitiveElement(el)) {
                return JSON.stringify({ success: false, error: 'SENSITIVE_CONTROL_BLOCKED', details: '민감 정보 또는 인증 관련 컨트롤은 조작할 수 없습니다.' });
            }

            // Fingerprint integrity validation
            if (expectedFp) {
                const currentTag = (el.tagName || '').toUpperCase();
                const currentType = (el.getAttribute('type') || el.type || '').toLowerCase();
                const currentHref = (currentTag === 'A' && el.href) ? el.href : '';
                const currentAccessibleName = getAccessibleName(el);
                const currentId = el.getAttribute('id') || '';
                const currentName = el.getAttribute('name') || '';
                const currentFormAction = el.getAttribute('formaction') || (el.formAction || '');
                const currentIsSubmit = isSubmitLikeElement(el);

                if (currentTag !== expectedFp.tag ||
                    currentType !== expectedFp.type ||
                    currentHref !== expectedFp.href ||
                    currentAccessibleName !== (expectedFp.name || '') ||
                    currentId !== (expectedFp.id || '') ||
                    currentName !== (expectedFp.elementName || '') ||
                    currentFormAction !== (expectedFp.formAction || '') ||
                    currentIsSubmit !== expectedFp.isSubmitLike) {
                    return JSON.stringify({ success: false, error: 'FINGERPRINT_MISMATCH', details: '요소의 태그, 타입, 식별자, 접근성 이름 또는 제출 동작 특성이 스냅샷 시점과 다릅니다.' });
                }
            }

            if (actionType === 'click') {
                // Ensure scrolled into view
                try {
                    el.scrollIntoView({ behavior: 'instant', block: 'center', inline: 'center' });
                } catch (_) {}

                el.focus();

                const doc = el.ownerDocument || document;
                const view = doc.defaultView || window;
                const opts = { bubbles: true, cancelable: true, composed: true, view: view };
                const PointerEvt = view.PointerEvent || window.PointerEvent;
                const MouseEvt = view.MouseEvent || window.MouseEvent;
                el.dispatchEvent(new PointerEvt('pointerdown', opts));
                el.dispatchEvent(new MouseEvt('mousedown', opts));
                el.dispatchEvent(new PointerEvt('pointerup', opts));
                el.dispatchEvent(new MouseEvt('mouseup', opts));
                el.dispatchEvent(new MouseEvt('click', opts));

                let resolvedHref = null;
                if (el.tagName.toUpperCase() === 'A' && el.href) {
                    resolvedHref = el.href;
                }

                return JSON.stringify({
                    success: true,
                    performed: 'click',
                    ref: ref,
                    resolvedHref: resolvedHref
                });
            } else if (actionType === 'fill') {
                if (isSensitiveElement(el)) {
                    return JSON.stringify({ success: false, error: 'SENSITIVE_INPUT_BLOCKED', details: '비밀번호 또는 보안 인증 필드에는 자동 입력을 수행할 수 없습니다.' });
                }

                const rawText = action.text !== undefined ? action.text : (action.value !== undefined ? action.value : '');
                if (typeof rawText !== 'string' && typeof rawText !== 'number') {
                    return JSON.stringify({ success: false, error: 'INVALID_INPUT_TYPE', details: '입력 텍스트는 문자열 또는 숫자여야 합니다.' });
                }
                const fillText = String(rawText).substring(0, 4000);

                const elTag = el.tagName.toUpperCase();
                const elType = (el.getAttribute('type') || el.type || '').toLowerCase();
                if (elTag === 'INPUT') {
                    if (['submit', 'button', 'reset', 'checkbox', 'radio', 'file', 'image', 'color', 'hidden', 'password'].includes(elType)) {
                        return JSON.stringify({ success: false, error: 'WRONG_INPUT_TYPE', details: '해당 입력 타입에는 텍스트를 채울 수 없습니다: ' + elType });
                    }
                }

                try {
                    el.scrollIntoView({ behavior: 'instant', block: 'center', inline: 'center' });
                } catch (_) {}

                el.focus();

                const doc = el.ownerDocument || document;
                const view = doc.defaultView || window;

                if (el.isContentEditable || el.getAttribute('contenteditable') === 'true') {
                    // Contenteditable
                    const selection = (view.getSelection ? view.getSelection() : window.getSelection());
                    const range = doc.createRange ? doc.createRange() : document.createRange();
                    range.selectNodeContents(el);
                    if (selection) {
                        selection.removeAllRanges();
                        selection.addRange(range);
                    }

                    let inserted = false;
                    try {
                        inserted = doc.execCommand ? doc.execCommand('insertText', false, fillText) : false;
                    } catch (_) {}

                    if (!inserted) {
                        el.innerText = fillText;
                    }
                    const InputEvt = view.InputEvent || window.InputEvent;
                    const Evt = view.Event || window.Event;
                    el.dispatchEvent(new InputEvt('input', { bubbles: true, cancelable: true, composed: true, inputType: 'insertText', data: fillText }));
                    el.dispatchEvent(new Evt('change', { bubbles: true, composed: true }));
                } else if (elTag === 'INPUT' || elTag === 'TEXTAREA') {
                    const proto = elTag === 'TEXTAREA' ? (view.HTMLTextAreaElement || window.HTMLTextAreaElement).prototype : (view.HTMLInputElement || window.HTMLInputElement).prototype;
                    const descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
                    if (descriptor && descriptor.set) {
                        descriptor.set.call(el, fillText);
                    } else {
                        el.value = fillText;
                    }
                    const Evt = view.Event || window.Event;
                    el.dispatchEvent(new Evt('input', { bubbles: true, composed: true }));
                    el.dispatchEvent(new Evt('change', { bubbles: true, composed: true }));
                } else {
                    return JSON.stringify({ success: false, error: 'NOT_AN_INPUT_ELEMENT', details: '텍스트를 입력할 수 있는 요소가 아닙니다.' });
                }

                return JSON.stringify({
                    success: true,
                    performed: 'fill',
                    ref: ref,
                    textLength: fillText.length
                });
            } else if (actionType === 'select') {
                if (el.tagName.toUpperCase() !== 'SELECT') {
                    return JSON.stringify({ success: false, error: 'NOT_A_SELECT_ELEMENT', details: '선택(select) 요소가 아닙니다.' });
                }

                const rawVal = action.value !== undefined ? action.value : (action.text !== undefined ? action.text : '');
                if (typeof rawVal !== 'string' && typeof rawVal !== 'number') {
                    return JSON.stringify({ success: false, error: 'INVALID_SELECT_VALUE', details: '선택 값은 문자열 또는 숫자여야 합니다.' });
                }
                const targetValue = String(rawVal).trim().substring(0, 1000);
                let matched = false;

                for (let i = 0; i < el.options.length; i++) {
                    const opt = el.options[i];
                    if (opt.value === targetValue || opt.text.trim() === targetValue) {
                        el.selectedIndex = i;
                        matched = true;
                        break;
                    }
                }

                if (!matched) {
                    return JSON.stringify({ success: false, error: 'OPTION_NOT_FOUND', details: '일치하는 옵션을 찾지 못했습니다: ' + targetValue });
                }

                const doc = el.ownerDocument || document;
                const view = doc.defaultView || window;
                const Evt = view.Event || window.Event;
                el.dispatchEvent(new Evt('change', { bubbles: true, composed: true }));
                el.dispatchEvent(new Evt('input', { bubbles: true, composed: true }));

                return JSON.stringify({
                    success: true,
                    performed: 'select',
                    ref: ref,
                    selectedValue: el.value
                });
            } else {
                return JSON.stringify({ success: false, error: 'UNKNOWN_ACTION_TYPE', details: '알 수 없는 동작 유형입니다: ' + actionType });
            }
        } catch (err) {
            return JSON.stringify({ success: false, error: '동작 수행 중 오류: ' + (err && err.message ? err.message : String(err)) });
        }
    };

    window.__HTT_WEB_AGENT_RUNTIME__ = RUNTIME;
})();
