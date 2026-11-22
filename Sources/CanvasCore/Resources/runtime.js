// Canvas artboard runtime. Inlined into every artboard's <head> before the body parses.
// Exposes only `window.Canvas`; Swift drives it through evaluateJavaScript.
(() => {
  if (window.Canvas) return;

  // MARK: - Messages to Swift

  const post = (message) => {
    try {
      window.webkit?.messageHandlers?.canvas?.postMessage(message);
    } catch {
      // No handler installed (or it rejected the message): stay silent.
    }
  };

  const truncate = (text, limit) => (text.length > limit ? text.slice(0, limit) : text);

  const headElement = () => document.head ?? document.documentElement;

  const CAPTURE = { capture: true };

  // MARK: - Console capture

  const MAX_LOGS = 200;
  const MAX_LOG_MESSAGE_LENGTH = 10000;
  const CAPTURED_LEVELS = ["log", "info", "warn", "error", "debug"];
  const logs = [];

  const describe = (value) => {
    if (typeof value === "string") return value;
    if (value instanceof Error) return value.stack ? `${value}\n${value.stack}` : String(value);
    try {
      return JSON.stringify(value) ?? String(value);
    } catch {
      return String(value);
    }
  };

  const record = (level, fullMessage) => {
    const message = truncate(fullMessage, MAX_LOG_MESSAGE_LENGTH);
    logs.push({ level, message, time: Date.now() });
    if (logs.length > MAX_LOGS) logs.splice(0, logs.length - MAX_LOGS);
    post({ type: "console", level, message });
  };

  const captureConsole = () => {
    for (const level of CAPTURED_LEVELS) {
      const original = console[level];
      console[level] = (...args) => {
        record(level, args.map(describe).join(" "));
        return original.apply(console, args);
      };
    }
  };

  const captureErrors = () => {
    window.addEventListener("error", (event) => record("error", event.error ? describe(event.error) : event.message));
    window.addEventListener("unhandledrejection", (event) =>
      record("error", `Unhandled rejection: ${describe(event.reason)}`)
    );
  };

  // MARK: - Pause gate for timers and animation frames

  let paused = false;
  const native = {
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    setTimeout: window.setTimeout.bind(window),
    clearTimeout: window.clearTimeout.bind(window),
  };
  // The page holds stable ids; the native timers and frames behind them are dropped on pause and rescheduled on resume.
  // timers: id → { run, period, repeats, due, remaining, nativeId }; frames: id → { callback, nativeId }.
  const timers = new Map();
  const frames = new Map();
  let lastId = 0;
  const nextId = () => ++lastId;

  const reportError = (error) => {
    if (window.reportError) window.reportError(error);
    else native.setTimeout(() => { throw error; });
  };

  const runReportingErrors = (run) => {
    try {
      run();
    } catch (error) {
      reportError(error);
    }
  };

  const asCallback = (handler) => (typeof handler === "function" ? handler : () => (0, eval)(String(handler)));

  const scheduleTimer = (id, timer, wait) => {
    timer.due = performance.now() + wait;
    timer.nativeId = native.setTimeout(() => fireTimer(id, timer), wait);
  };

  // An interval books its next tick before running, so a throwing callback doesn't stop it.
  const fireTimer = (id, timer) => {
    if (timer.repeats) scheduleTimer(id, timer, timer.period);
    else timers.delete(id);
    runReportingErrors(timer.run);
  };

  // A timer added while paused waits its whole delay from resume.
  const addTimer = (handler, delay, args, repeats) => {
    const id = nextId();
    const callback = asCallback(handler);
    const period = Math.max(0, Number(delay) || 0);
    const timer = { run: () => callback.apply(window, args), period, repeats, remaining: period };
    timers.set(id, timer);
    if (!paused) scheduleTimer(id, timer, period);
    return id;
  };

  const clearTimer = (id) => {
    native.clearTimeout(timers.get(id)?.nativeId);
    timers.delete(id);
  };

  const suspendTimer = (timer) => {
    native.clearTimeout(timer.nativeId);
    timer.remaining = Math.max(0, timer.due - performance.now());
  };

  const requestFrame = (id, frame) => {
    frame.nativeId = native.requestAnimationFrame((time) => {
      frames.delete(id);
      runReportingErrors(() => frame.callback.call(window, time));
    });
  };

  // A frame requested while paused waits for resume without waking the page.
  const addFrame = (callback) => {
    const id = nextId();
    const frame = { callback };
    frames.set(id, frame);
    if (!paused) requestFrame(id, frame);
    return id;
  };

  const cancelFrame = (id) => {
    native.cancelAnimationFrame(frames.get(id)?.nativeId);
    frames.delete(id);
  };

  const suspendTimersAndFrames = () => {
    timers.forEach(suspendTimer);
    frames.forEach((frame) => native.cancelAnimationFrame(frame.nativeId));
  };

  // Timers pick up where they left off (an interval's first tick comes after its remaining time); frames get the next one.
  const resumeTimersAndFrames = () => {
    timers.forEach((timer, id) => scheduleTimer(id, timer, timer.remaining));
    frames.forEach((frame, id) => requestFrame(id, frame));
  };

  const gateTimers = () => {
    window.requestAnimationFrame = addFrame;
    window.cancelAnimationFrame = cancelFrame;
    window.setTimeout = (handler, delay, ...args) => addTimer(handler, delay, args, false);
    window.setInterval = (handler, delay, ...args) => addTimer(handler, delay, args, true);
    window.clearTimeout = clearTimer;
    window.clearInterval = clearTimer;
  };

  // MARK: - Pause for animations and media

  const PAUSED_CLASS = "canvas-paused";
  const RESTARTING_CLASS = "canvas-restarting";
  const everythingIn = (scope) => `${scope}*, ${scope}*::before, ${scope}*::after`;
  const PAUSED_DECLARATION = "{ animation-play-state: paused !important; }";
  const NO_ANIMATION_DECLARATION = "{ animation-name: none !important; }";
  const DOCUMENT_RULES =
    `${everythingIn(`html.${PAUSED_CLASS} `)} ${PAUSED_DECLARATION}\n` +
    `${everythingIn(`html.${RESTARTING_CLASS} `)} ${NO_ANIMATION_DECLARATION}`;

  const styleSheet = (rules) => {
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(rules);
    return sheet;
  };

  // Shadow-root twins of the document rules, adopted only while needed: document styles can't reach inside.
  const shadowPauseSheet = styleSheet(`${everythingIn("")} ${PAUSED_DECLARATION}`);
  const shadowRestartSheet = styleSheet(`${everythingIn("")} ${NO_ANIMATION_DECLARATION}`);
  const pausedAnimations = new Set();
  const pausedMedia = new Set();
  // The document and the shadow roots that pause() touched, so resume() undoes it even in closed roots.
  const pausedRoots = new Set();
  // Animations made with element.animate() → their keyframes as JSON: finished ones without a fill drop out of
  // getAnimations(), so restart needs this list to replay them. Capped as a backstop; Maps keep insertion order.
  const scriptedAnimations = new Map();
  const MAX_SCRIPTED_ANIMATIONS = 200;

  const installDocumentRules = () => {
    const style = document.createElement("style");
    style.id = "canvas-pause";
    style.textContent = DOCUMENT_RULES;
    headElement().append(style);
  };

  const openShadowRoots = (root = document) =>
    [...root.querySelectorAll("*")].flatMap((el) => (el.shadowRoot ? [el.shadowRoot, ...openShadowRoots(el.shadowRoot)] : []));

  // WebKit's document.getAnimations() skips shadow trees, so collectors take every open shadow root too.
  const allRoots = (shadowRoots = openShadowRoots()) => [document, ...shadowRoots];

  const isAttached = (animation) => animation.effect?.target?.isConnected ?? true;

  const isCSSAnimation = (animation) => animation instanceof CSSAnimation;

  // Scripted animations whose element left the page are forgotten, so the set doesn't grow forever.
  const liveScriptedAnimations = () => {
    scriptedAnimations.forEach((_, animation) => isAttached(animation) || scriptedAnimations.delete(animation));
    return [...scriptedAnimations.keys()];
  };

  const animationsIn = (roots) => [...new Set([...roots.flatMap((root) => root.getAnimations()), ...liveScriptedAnimations()])];

  const mediaIn = (roots) => roots.flatMap((root) => [...root.querySelectorAll("video, audio")]);

  const playMedia = (media) => media.play()?.catch(() => {});

  const adoptSheet = (root, sheet) => {
    if (!root.adoptedStyleSheets.includes(sheet)) root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet];
  };

  const dropSheet = (root, sheet) => {
    root.adoptedStyleSheets = root.adoptedStyleSheets.filter((adopted) => adopted !== sheet);
  };

  // Pauses a running animation and remembers it, so resume plays only what pause stopped.
  const freeze = (animation) => {
    if (animation.playState !== "running") return;
    pausedAnimations.add(animation);
    animation.pause();
    // Seeking completes the pending pause now, so the frame freezes at this instant.
    animation.currentTime = animation.currentTime;
  };

  const pauseMediaElement = (media) => {
    if (media.paused) return;
    pausedMedia.add(media);
    media.pause();
  };

  const resumeAnimations = () => {
    [...pausedAnimations].filter(isAttached).forEach((animation) => animation.play());
    pausedAnimations.clear();
  };

  const resumeMedia = () => {
    [...pausedMedia].filter((media) => media.isConnected).forEach(playMedia);
    pausedMedia.clear();
  };

  // `play` isn't composed, so each root listens for its own media; held media plays on resume, as the page asked.
  const holdMediaThatStartsPlaying = (event) => {
    if (event.target instanceof HTMLMediaElement) pauseMediaElement(event.target);
  };

  const pauseRoot = (root) => {
    pausedRoots.add(root);
    root.addEventListener("play", holdMediaThatStartsPlaying, CAPTURE);
    if (root instanceof ShadowRoot) adoptSheet(root, shadowPauseSheet);
  };

  const resumeRoot = (root) => {
    root.removeEventListener("play", holdMediaThatStartsPlaying, CAPTURE);
    if (root instanceof ShadowRoot) dropSheet(root, shadowPauseSheet);
  };

  // Calls `after(result)` with the result of every call to `prototype[name]`.
  const wrapMethod = (prototype, name, after) => {
    prototype[name] = new Proxy(prototype[name], {
      apply: (method, receiver, args) => {
        const result = Reflect.apply(method, receiver, args);
        after(result);
        return result;
      },
    });
  };

  const forgetScriptedAnimation = (animation) => scriptedAnimations.delete(animation);

  const keyframesOf = (animation) => JSON.stringify(animation.effect?.getKeyframes?.() ?? []);

  const isEarlierFinishedRunOf = (animation, other) =>
    other !== animation &&
    other.playState === "finished" &&
    other.effect?.target === animation.effect?.target &&
    scriptedAnimations.get(other) === scriptedAnimations.get(animation);

  // A one-shot replayed by script (a pulse, a hover flash) supersedes its earlier finished runs on that element.
  const forgetEarlierRuns = (animation) =>
    [...scriptedAnimations.keys()].filter((other) => isEarlierFinishedRunOf(animation, other)).forEach(forgetScriptedAnimation);

  const forgetOldestPastCap = () => {
    if (scriptedAnimations.size > MAX_SCRIPTED_ANIMATIONS) forgetScriptedAnimation(scriptedAnimations.keys().next().value);
  };

  const forgetWhenSuperseded = (animation) => {
    animation.addEventListener("cancel", () => forgetScriptedAnimation(animation));
    animation.addEventListener("remove", () => forgetScriptedAnimation(animation));
    animation.addEventListener("finish", () => forgetEarlierRuns(animation));
  };

  const trackScriptedAnimation = (animation) => {
    scriptedAnimations.set(animation, keyframesOf(animation));
    forgetOldestPastCap();
    forgetWhenSuperseded(animation);
    if (paused) freeze(animation);
  };

  const pauseRootAttachedWhilePaused = (root) => {
    if (paused) pauseRoot(root);
  };

  // Animations and shadow roots the page creates while paused start out paused too.
  const watchNewAnimationsAndShadowRoots = () => {
    wrapMethod(Element.prototype, "animate", trackScriptedAnimation);
    wrapMethod(Element.prototype, "attachShadow", pauseRootAttachedWhilePaused);
  };

  const pause = () => {
    if (paused) return;
    paused = true;
    document.documentElement.classList.add(PAUSED_CLASS);
    const roots = allRoots();
    roots.forEach(pauseRoot);
    animationsIn(roots).forEach(freeze);
    mediaIn(roots).forEach(pauseMediaElement);
    suspendTimersAndFrames();
  };

  const resume = () => {
    if (!paused) return;
    paused = false;
    document.documentElement.classList.remove(PAUSED_CLASS);
    pausedRoots.forEach(resumeRoot);
    pausedRoots.clear();
    resumeAnimations();
    resumeMedia();
    resumeTimersAndFrames();
  };

  // Rewinds a scripted animation to 0. Plays only what was playing (or finished); ones the design paused stay paused.
  // (CSS animations are recreated running by replayCSSAnimations, even ones the page paused with anim.pause().)
  const restartAnimation = (animation) => {
    const wasPlaying = animation.playState === "running" || animation.playState === "finished";
    animation.currentTime = 0;
    // Seeking a finished animation sets it running again, so re-freeze it while paused.
    if (paused) freeze(animation);
    else if (wasPlaying) animation.play();
  };

  // Rewinds to 0; media that had ended plays again (on resume, if paused).
  const restartMedia = (media) => {
    const ended = media.ended;
    media.currentTime = 0;
    if (!ended) return;
    if (paused) pausedMedia.add(media);
    else playMedia(media);
  };

  const setRestarting = (on, shadowRoots) => {
    document.documentElement.classList.toggle(RESTARTING_CLASS, on);
    shadowRoots.forEach((root) => (on ? adoptSheet(root, shadowRestartSheet) : dropSheet(root, shadowRestartSheet)));
  };

  // Reading a layout value applies pending style changes across the whole page, shadow trees included.
  // (A computed style read only flushes when that element itself is dirty; the rules above dirty descendants.)
  const flushStyles = () => void document.documentElement.offsetWidth;

  // Frozen CSS animations are about to be replaced, so resume must not play the old ones.
  const forgetFrozenCSSAnimations = () =>
    pausedAnimations.forEach((animation) => isCSSAnimation(animation) && pausedAnimations.delete(animation));

  // Switching animation-name off and on again recreates every CSS animation at 0, finished ones included;
  // while paused the pause rule holds the new ones.
  const replayCSSAnimations = (shadowRoots) => {
    forgetFrozenCSSAnimations();
    setRestarting(true, shadowRoots);
    flushStyles();
    setRestarting(false, shadowRoots);
  };

  const restart = () => {
    const shadowRoots = openShadowRoots();
    replayCSSAnimations(shadowRoots);
    const roots = allRoots(shadowRoots);
    animationsIn(roots).filter((animation) => !isCSSAnimation(animation)).forEach(restartAnimation);
    mediaIn(roots).forEach(restartMedia);
  };

  // MARK: - Components

  const templates = new Map();
  const liveComponents = new Set();
  const propNamesByTemplate = new Map();

  const escapeHTML = (text) =>
    text.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);

  // `{{prop}}` / `{{ prop | default }}` → the host's attribute (escaped), else the trimmed default, else "".
  // Same grammar as Swift's ComponentTemplate.props.
  const PLACEHOLDER = /\{\{\s*([A-Za-z_][\w-]*)\s*(?:\|([^}]*))?\}\}/g;

  const fillTemplate = (template, host) =>
    template.replace(PLACEHOLDER, (_, prop, fallback) => {
      const value = host.getAttribute(prop);
      return escapeHTML(value ?? fallback?.trim() ?? "");
    });

  const templateOf = (component) => templates.get(component.componentName) ?? "";

  // Attribute names are lowercase in HTML, so props are compared lowercased.
  const propNamesOf = (template) => {
    if (!propNamesByTemplate.has(template)) {
      const names = [...template.matchAll(PLACEHOLDER)].map(([, prop]) => prop.toLowerCase());
      propNamesByTemplate.set(template, new Set(names));
    }
    return propNamesByTemplate.get(template);
  };

  const changesAUsedProp = (record) =>
    record.oldValue !== record.target.getAttribute(record.attributeName) &&
    propNamesOf(templateOf(record.target)).has(record.attributeName);

  // Templates have no conditionals, so a component inside its own template nests forever; slotted
  // same-tag nesting is legitimate, hence a depth rather than any repeat. The overall cap stops cycles
  // through several components before they multiply.
  const MAX_SAME_TAG_ANCESTORS = 8;
  const MAX_COMPONENT_DEPTH = 32;
  const reportedSelfIncludes = new Set();

  const parentAcrossShadowRoots = (element) => {
    if (element.parentElement) return element.parentElement;
    const root = element.getRootNode();
    return root instanceof ShadowRoot ? root.host : null;
  };

  const componentAncestors = (component) => {
    const ancestors = [];
    for (let ancestor = parentAcrossShadowRoots(component); ancestor; ancestor = parentAcrossShadowRoots(ancestor)) {
      if (ancestor instanceof CanvasComponent) ancestors.push(ancestor);
    }
    return ancestors;
  };

  const nestsTooDeeply = (component) => {
    const ancestors = componentAncestors(component);
    const sameTag = ancestors.filter((ancestor) => ancestor.localName === component.localName);
    return ancestors.length >= MAX_COMPONENT_DEPTH || sameTag.length >= MAX_SAME_TAG_ANCESTORS;
  };

  const reportSelfInclude = (tag) => {
    if (reportedSelfIncludes.has(tag)) return;
    reportedSelfIncludes.add(tag);
    console.error(`Canvas: <${tag}> includes itself`);
  };

  const includesItself = (component) => {
    if (!nestsTooDeeply(component)) return false;
    reportSelfInclude(component.localName);
    return true;
  };

  // One observer for every component: each affected host renders at most once per batch.
  const attributeObserver = new MutationObserver((records) => {
    const stale = new Set(records.filter(changesAUsedProp).map((record) => record.target));
    stale.forEach((component) => component.isConnected && component.render());
  });

  class CanvasComponent extends HTMLElement {
    get componentName() {
      return this.localName.slice("x-".length);
    }

    // Observing from here (not the constructor) skips attributes set before insertion; this render covers them.
    connectedCallback() {
      liveComponents.add(this);
      attributeObserver.observe(this, { attributes: true, attributeOldValue: true });
      this.render();
    }

    disconnectedCallback() {
      liveComponents.delete(this);
    }

    render() {
      const root = this.shadowRoot ?? this.attachShadow({ mode: "open" });
      if (paused) pauseRoot(root);
      root.innerHTML = includesItself(this) ? "" : fillTemplate(templateOf(this), this);
    }
  }

  const defineComponent = (name) => {
    const tag = `x-${name}`;
    if (customElements.get(tag)) return;
    try {
      customElements.define(tag, class extends CanvasComponent {});
    } catch (error) {
      console.error(`Canvas: cannot define <${tag}>:`, error);
    }
  };

  // Rendering an outer instance replaces the nested ones, so connection is checked at each render.
  const rerenderComponents = (names) =>
    [...liveComponents]
      .filter((component) => names.has(component.componentName))
      .forEach((component) => component.isConnected && component.render());

  const defineComponents = (map) => {
    const names = new Set(Object.keys(map ?? {}));
    names.forEach((name) => templates.set(name, String(map[name])));
    rerenderComponents(names);
    names.forEach(defineComponent);
  };

  // MARK: - Tokens and mode

  const setTokens = (css) => {
    let style = document.getElementById("canvas-tokens");
    if (!style) {
      style = document.createElement("style");
      style.id = "canvas-tokens";
      headElement().append(style);
    }
    style.textContent = css;
  };

  const setMode = (mode) => {
    document.documentElement.dataset.mode = mode;
  };

  // MARK: - Inspect

  // The most HTML a selection message or `Canvas.describe` carries (`PageElement.maxHTMLLength` in Swift).
  const MAX_OUTER_HTML_LENGTH = 20000;

  // The host's inline !important styles beat author rules; the closed shadow root keeps the box out of reach.
  const OVERLAY_HOST_STYLE = [
    "all:initial",
    "display:block",
    "position:fixed",
    "inset:0",
    "pointer-events:none",
    "z-index:2147483647",
  ].map((declaration) => `${declaration}!important`).join(";");
  const OVERLAY_SHADOW_HTML =
    "<style>div{position:fixed;display:none;box-sizing:border-box;margin:0;pointer-events:none;" +
    "outline:1.5px solid #3b82f6;background:rgba(59,130,246,0.12)}</style><div></div>";
  const BLOCKED_POINTER_EVENTS = ["pointerdown", "pointerup", "mousedown", "mouseup", "dblclick", "auxclick"];
  let overlay = null;
  let hovered = null;

  // Hits inside a component resolve to its outermost host: that is what exists in the source HTML.
  const sourceElement = (node) => {
    let element = node instanceof Element ? node : node?.parentElement;
    while (element && element.getRootNode() instanceof ShadowRoot) element = element.getRootNode().host;
    return element;
  };

  const isUniqueId = (element) =>
    element.id !== "" && document.querySelectorAll(`#${CSS.escape(element.id)}`).length === 1;

  const nthOfType = (element) => {
    const sameTag = [...element.parentElement.children].filter((sibling) => sibling.localName === element.localName);
    return `${element.localName}:nth-of-type(${sameTag.indexOf(element) + 1})`;
  };

  const selector = (target) => {
    const element = sourceElement(target);
    if (!element) return "";
    const path = [];
    for (let current = element; current; current = current.parentElement) {
      if (isUniqueId(current)) return [`#${CSS.escape(current.id)}`, ...path].join(" > ");
      if (current === document.body || !current.parentElement) return [current.localName, ...path].join(" > ");
      path.unshift(nthOfType(current));
    }
    return path.join(" > ");
  };

  const rectOf = (element) => {
    const { x, y, width, height } = element.getBoundingClientRect();
    return { x, y, width, height };
  };

  const selectionMessage = (element) => ({
    type: "select",
    selector: selector(element),
    tag: element.localName,
    outerHTML: truncate(element.outerHTML, MAX_OUTER_HTML_LENGTH),
    text: truncate(element.innerText ?? element.textContent ?? "", 2000),
    rect: rectOf(element),
  });

  const createOverlay = () => {
    const host = document.createElement("canvas-inspect-overlay");
    host.setAttribute("style", OVERLAY_HOST_STYLE);
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = OVERLAY_SHADOW_HTML;
    document.documentElement.append(host);
    return { host, box: root.querySelector("div") };
  };

  const drawHighlight = (element) => {
    hovered = element;
    const { x, y, width, height } = rectOf(element);
    Object.assign(overlay.box.style, { display: "block", left: `${x}px`, top: `${y}px`, width: `${width}px`, height: `${height}px` });
  };

  const highlightHovered = (event) => {
    const element = sourceElement(event.target);
    if (overlay && element && element !== document.documentElement) drawHighlight(element);
  };

  const followScroll = () => {
    if (overlay && hovered?.isConnected) drawHighlight(hovered);
  };

  const hideHighlightWhenPointerLeavesPage = (event) => {
    if (!overlay || event.relatedTarget) return;
    hovered = null;
    overlay.box.style.display = "none";
  };

  const swallow = (event) => {
    event.preventDefault();
    event.stopImmediatePropagation();
  };

  const selectOnClick = (event) => {
    swallow(event);
    const element = sourceElement(event.target);
    if (element) post(selectionMessage(element));
  };

  const exitOnEscape = (event) => {
    if (event.key !== "Escape") return;
    swallow(event);
    post({ type: "inspectExit" });
  };

  const inspectListeners = [
    ["mousemove", highlightHovered, CAPTURE],
    ["mouseout", hideHighlightWhenPointerLeavesPage, CAPTURE],
    ["scroll", followScroll, { capture: true, passive: true }],
    ["click", selectOnClick, CAPTURE],
    ["keydown", exitOnEscape, CAPTURE],
    ...BLOCKED_POINTER_EVENTS.map((type) => [type, swallow, CAPTURE]),
  ];

  const startInspecting = () => {
    if (overlay) return;
    overlay = createOverlay();
    inspectListeners.forEach(([type, listener, options]) => window.addEventListener(type, listener, options));
  };

  const stopInspecting = () => {
    if (!overlay) return;
    inspectListeners.forEach(([type, listener, options]) => window.removeEventListener(type, listener, options));
    overlay.host.remove();
    overlay = null;
    hovered = null;
  };

  const inspect = (on) => (on ? startInspecting() : stopInspecting());

  // MARK: - Pointers

  // What a right-click on the canvas and the `get_element` tool ask about an element. Coordinates and boxes are
  // in the page's CSS pixels; the page itself (<html>, <body>) is not an element here.
  const KEY_STYLES = [
    "display", "position", "width", "height", "margin", "padding", "color", "background-color",
    "font-family", "font-size", "font-weight", "line-height",
  ];

  const keyStyles = (element) => {
    const computed = getComputedStyle(element);
    return Object.fromEntries(KEY_STYLES.map((property) => [property, computed.getPropertyValue(property)]));
  };

  const elementInfo = (element) => ({
    selector: selector(element),
    outerHTML: element.outerHTML,
    box: rectOf(element),
    styles: keyStyles(element),
  });

  const isPage = (element) => !element || element === document.documentElement || element === document.body;

  // Every match, or null for a malformed selector.
  const queryAll = (selectorText) => {
    try {
      return document.querySelectorAll(selectorText);
    } catch {
      return null;
    }
  };

  // The whole element: a right-click copies its full HTML.
  const elementAt = (x, y) => {
    const element = sourceElement(document.elementFromPoint(x, y));
    return isPage(element) ? null : elementInfo(element);
  };

  // The first match, with the match count and its HTML capped for an agent; null for none.
  const describeSelector = (selectorText) => {
    const matches = queryAll(selectorText);
    if (!matches) return { invalidSelector: true };
    if (matches.length === 0) return null;
    const info = { ...elementInfo(matches[0]), matches: matches.length };
    if (info.outerHTML.length <= MAX_OUTER_HTML_LENGTH) return info;
    return { ...info, outerHTML: truncate(info.outerHTML, MAX_OUTER_HTML_LENGTH), truncated: true };
  };

  // MARK: - Settled (what an off-screen snapshot waits for)

  const SETTLE_LIMIT_MS = 3000;

  // The native timer and frame, so pause() can't stretch the wait.
  const nativeDelay = (ms) => new Promise((resolve) => native.setTimeout(resolve, ms));

  const nextFrame = () => new Promise((resolve) => native.requestAnimationFrame(resolve));

  const endsOnItsOwn = (animation) => Number.isFinite(animation.effect?.getComputedTiming().endTime);

  // Only running animations count: a paused page settles at once, and a pause mid-wait runs to the cap.
  const runningEntrances = () =>
    animationsIn(allRoots()).filter((animation) => animation.playState === "running" && endsOnItsOwn(animation));

  // A cancelled animation rejects `finished`; it counts as done.
  const whenFinished = (animation) => animation.finished.catch(() => {});

  // Two frames first, so animations declared in CSS at load exist; then again for any that start as others end,
  // a frame after each batch (`finished` resolves before `animationend` handlers run), until the deadline.
  const entrancesFinished = async (deadline) => {
    await nextFrame();
    await nextFrame();
    await document.fonts.ready;
    for (let running = runningEntrances(); running.length && performance.now() < deadline; running = runningEntrances()) {
      await Promise.all(running.map(whenFinished));
      await nextFrame();
    }
  };

  // Resolves once web fonts load and every finite animation finishes, or after SETTLE_LIMIT_MS, whichever comes first.
  const settled = () =>
    Promise.race([entrancesFinished(performance.now() + SETTLE_LIMIT_MS), nativeDelay(SETTLE_LIMIT_MS)]).then(() => undefined);

  // MARK: - Ready

  const announceReady = () => post({ type: "ready" });

  const announceReadyWhenParsed = () => {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", announceReady, { once: true });
    else announceReady();
  };

  // MARK: - Boot

  captureConsole();
  captureErrors();
  gateTimers();
  watchNewAnimationsAndShadowRoots();
  installDocumentRules();
  announceReadyWhenParsed();

  const api = Object.freeze({
    defineComponents,
    setTokens,
    setMode,
    pause,
    resume,
    restart,
    get isPaused() {
      return paused;
    },
    inspect,
    selector,
    elementAt,
    describe: describeSelector,
    settled,
    logs,
  });

  Object.defineProperty(window, "Canvas", { value: api, writable: false, configurable: false, enumerable: true });
})();
