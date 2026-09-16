enum OverlayPageChanges {
    static let install = """
        (() => {
            document.body.style.backgroundColor = 'transparent';
            const state = { dirty: true, mediaDirty: true, media: [], opaqueStyles: false,
                            styleText: '', wasAnimating: false };
            state.readStyles = () => {
                let text = '';
                try {
                    for (const sheet of document.styleSheets) {
                        // Bound inspection work. Complex/opaque stylesheets
                        // retain continuous refresh rather than risk freezing.
                        if (sheet.cssRules.length > 256) return null;
                        for (const rule of sheet.cssRules) {
                            text += rule.cssText;
                            if (text.length > 32768) return null;
                        }
                    }
                } catch (_) { return null; }
                return text;
            };
            const updateMedia = () => {
                // Conservatively refresh media whose pixels can change without
                // DOM mutations, including animated images and embedded pages.
                state.media = Array.from(document.querySelectorAll(
                    'img,canvas,video,iframe,object,embed,svg animate,svg animateTransform,svg animateMotion,marquee,[style*="url("]'
                ));
                // CSS backgrounds may contain animated images, and a stylesheet
                // from another origin cannot be inspected. Preserve animations
                // conservatively instead of guessing that those pages are idle.
                state.opaqueStyles = Array.from(document.styleSheets).some(sheet => {
                    try { return Array.from(sheet.cssRules).some(rule => /url\\(|@import/i.test(rule.cssText)); }
                    catch (_) { return true; }
                }) || Array.from(document.querySelectorAll('*')).some(element => element.shadowRoot);
                state.mediaDirty = false;
            };
            state.updateMedia = updateMedia;
            new MutationObserver(changes => {
                state.dirty = true;
                if (changes.some(change => change.type !== 'characterData')) state.mediaDirty = true;
                window.webkit.messageHandlers.domChanged.postMessage('DOM changed');
            }).observe(document, {
                subtree: true, childList: true, characterData: true, attributes: true
            });
            document.addEventListener('load', () => {
                state.dirty = true;
                state.mediaDirty = true;
                window.webkit.messageHandlers.domChanged.postMessage('Loaded content');
            }, true);
            window.__tubeistOverlayChanges = state;
        })();
        """

    static let consume = """
        (() => {
            const state = window.__tubeistOverlayChanges;
            if (!state) return true;
            // CSSOM edits do not produce MutationObserver callbacks.
            const styles = state.readStyles();
            if (styles !== state.styleText) {
                state.styleText = styles;
                state.mediaDirty = true;
                state.dirty = true;
            }
            if (state.mediaDirty) state.updateMedia();
            const dirty = state.dirty;
            state.dirty = false;
            const animating = state.media.some(element =>
                element.tagName !== 'VIDEO' || (!element.paused && !element.ended)
            ) || document.getAnimations().some(animation =>
                animation.playState === 'running' || animation.pending
            );
            // Take the exact final frame when an animation finishes or pauses.
            const justStopped = state.wasAnimating && !animating;
            state.wasAnimating = animating;
            return dirty || styles === null || state.opaqueStyles || animating || justStopped;
        })();
        """
}
