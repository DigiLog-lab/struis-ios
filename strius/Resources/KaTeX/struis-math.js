// Struis: 本文と数式を KaTeX で描く。KaTeXMathText(Swift)が読み込む同梱ファイル。
// HTML に毎回埋め込まず、WebView はこのファイルと katex.min.js をファイルから読む(K1)。
// 描き直しは struisRender を呼ぶだけで、ページを読み込み直さない。
(function () {
  "use strict";
  let STRUIS_MARK = 0;
  let currentKey = "";

  function setStruisHighlight(count) {
    document.querySelectorAll("[data-struis-mark]").forEach((el) => {
      el.classList.toggle("struis-hl", Number(el.getAttribute("data-struis-mark")) < count);
    });
  }
  window.setStruisHighlight = setStruisHighlight;

  const DOUBLE_ESCAPED_LATEX_COMMANDS = new Set([
    "alpha","angle","bar","begin","beta","binom","cap","cdot","cdots","cos","cosh","cup",
    "delta","det","div","displaystyle","ddots","end","epsilon","exp","exists","forall",
    "frac","gamma","ge","hat","in","infty","int","lambda","land","ldots","le","leftarrow",
    "Leftrightarrow","left","lim","ln","log","lor","lnot","mathbb","mathrm","mathit",
    "mathbf","mp","mu","nabla","ne","neq","notin","omega","operatorname","overline",
    "partial","parallel","perp","phi","pi","pm","prod","qquad","quad","right","Rightarrow",
    "rightarrow","rho","sigma","sin","sinh","sqrt","sum","tan","tanh","text","textstyle",
    "theta","therefore","times","to","triangle","underline","varepsilon","varphi","vec"
  ]);

  function normalizeLatexEscapes(src) {
    return String(src || "")
      .replace(/\\([\[\]()])/g, "\\$1")
      .replace(/\\{2,}([A-Za-z]+)/g, (match, command) =>
        DOUBLE_ESCAPED_LATEX_COMMANDS.has(command) ? `\\${command}` : match
      )
      .replace(/\\\\([A-Za-z]+)/g, (match, command) =>
        DOUBLE_ESCAPED_LATEX_COMMANDS.has(command) ? `\\${command}` : match
      );
  }

  function tokenize(src) {
    const out = [];
    let i = 0;
    while (i < src.length) {
      const displayFence = readDelimited(src, i, "$$", "$$") || readDelimited(src, i, "\\[", "\\]");
      if (displayFence) {
        out.push({ kind: "display", body: displayFence.body });
        i = displayFence.end;
        continue;
      }
      const inlineFence = readDelimited(src, i, "\\(", "\\)") || readInlineDollar(src, i);
      if (inlineFence) {
        out.push({ kind: "inline", body: inlineFence.body });
        i = inlineFence.end;
        continue;
      }
      const environment = readLatexEnvironment(src, i);
      if (environment) {
        out.push({ kind: "display", body: environment.body });
        i = environment.end;
        continue;
      }
      const j = nextTokenStart(src, i + 1);
      out.push({ kind: "text", body: src.slice(i, j) });
      i = j;
    }
    return out;
  }

  function readDelimited(src, start, open, close) {
    if (!src.startsWith(open, start)) return null;
    const end = findUnescaped(src, close, start + open.length);
    if (end < 0) return null;
    return { body: src.slice(start + open.length, end).trim(), end: end + close.length };
  }

  function readInlineDollar(src, start) {
    if (src[start] !== "$" || src[start + 1] === "$" || isEscaped(src, start)) return null;
    const end = findUnescaped(src, "$", start + 1);
    if (end <= start) return null;
    return { body: src.slice(start + 1, end).trim(), end: end + 1 };
  }

  function readLatexEnvironment(src, start) {
    const match = /^\\begin\{([A-Za-z*]+)\}/.exec(src.slice(start));
    if (!match) return null;
    const close = `\\end{${match[1]}}`;
    const closeIndex = src.indexOf(close, start + match[0].length);
    if (closeIndex < 0) return null;
    return { body: src.slice(start, closeIndex + close.length).trim(), end: closeIndex + close.length };
  }

  function nextTokenStart(src, from) {
    const candidates = ["$$", "$", "\\[", "\\(", "\\begin{"]
      .map((needle) => findUnescaped(src, needle, from))
      .filter((index) => index >= 0);
    return candidates.length > 0 ? Math.min(...candidates) : src.length;
  }

  function findUnescaped(src, needle, from) {
    let index = src.indexOf(needle, from);
    while (index >= 0) {
      if (!isEscaped(src, index)) return index;
      index = src.indexOf(needle, index + needle.length);
    }
    return -1;
  }

  function isEscaped(src, index) {
    let slashCount = 0;
    for (let i = index - 1; i >= 0 && src[i] === "\\"; i -= 1) slashCount += 1;
    return slashCount % 2 === 1;
  }

  function renderMixed(src, display) {
    const normalized = normalizeLatexEscapes(src);
    if (display && !/\$/.test(normalized) && isPureMath(normalized)) {
      return wrapMath(safeKatex(normalized, true), true);
    }
    let strongOpen = false;
    let out = "";
    let afterDisplay = false;
    for (const token of tokenize(normalized)) {
      // 表示用の数式は段落(ブロック)なので、その直後の改行 1 つは空行にしない。
      if (token.kind === "text" && afterDisplay) token.body = token.body.replace(/^\n/, "");
      afterDisplay = token.kind === "display";
      if (token.kind === "display") {
        const math = wrapMath(safeKatex(token.body, true), true);
        out += strongOpen ? `<strong>${math}</strong>` : math;
      } else if (token.kind === "inline") {
        const math = wrapMath(safeKatex(token.body, false), false);
        out += strongOpen ? `<strong>${math}</strong>` : math;
      } else {
        const rendered = renderTextMarkdown(token.body, strongOpen);
        out += rendered.html;
        strongOpen = rendered.strongOpen;
      }
    }
    if (strongOpen) out += "</strong>";
    return out;
  }

  function wrapMath(html, displayMode) {
    const kind = displayMode ? "display" : "inline";
    return `<span class="math-scroll math-scroll--${kind}" data-struis-mark="${STRUIS_MARK++}">${html}</span>`;
  }

  function safeKatex(body, displayMode) {
    const normalized = normalizeMathForKatex(body);
    try {
      const rendered = katex.renderToString(normalized, {
        displayMode,
        throwOnError: false,
        strict: "ignore",
        output: "html",
        trust: false
      });
      if (!rendered.includes("katex-error")) return rendered;
      return escapeHtml(normalized || body);
    } catch {
      return escapeHtml(normalized || body);
    }
  }

  function normalizeMathForKatex(body) {
    return normalizeMathScalars(normalizeLatexEscapes(String(body || "").trim()));
  }

  function normalizeMathScalars(body) {
    return normalizeScriptCharacters(body.normalize("NFKC"))
      .replace(/<=>|⇔/g, "\\Leftrightarrow ")
      .replace(/->|→/g, "\\to ")
      .replace(/<-|←/g, "\\leftarrow ")
      .replace(/=>|⇒/g, "\\Rightarrow ")
      .replace(/<=|≤/g, "\\le ")
      .replace(/>=|≥/g, "\\ge ")
      .replace(/!=|≠/g, "\\ne ")
      .replace(/−/g, "-")
      .replace(/×/g, "\\times ")
      .replace(/÷/g, "\\div ")
      .replace(/±/g, "\\pm ")
      .replace(/∞/g, "\\infty ")
      .replace(/√/g, "\\sqrt ");
  }

  const SUPERSCRIPTS = { "⁰":"0","¹":"1","²":"2","³":"3","⁴":"4","⁵":"5","⁶":"6","⁷":"7","⁸":"8","⁹":"9","ⁿ":"n","⁺":"+","⁻":"-" };
  const SUBSCRIPTS = { "₀":"0","₁":"1","₂":"2","₃":"3","₄":"4","₅":"5","₆":"6","₇":"7","₈":"8","₉":"9","ₙ":"n","₊":"+","₋":"-" };

  function normalizeScriptCharacters(value) {
    return value
      .replace(/[⁰¹²³⁴⁵⁶⁷⁸⁹ⁿ⁺⁻]+/g, (match) => `^{${[...match].map((char) => SUPERSCRIPTS[char] || char).join("")}}`)
      .replace(/[₀₁₂₃₄₅₆₇₈₉ₙ₊₋]+/g, (match) => `_{${[...match].map((char) => SUBSCRIPTS[char] || char).join("")}}`);
  }

  function renderTextMarkdown(s, strongOpen) {
    let out = "";
    let index = 0;
    const pattern = /(\*\*|__)/g;
    for (const match of s.matchAll(pattern)) {
      const start = match.index || 0;
      if (start > index) out += escapeHtml(s.slice(index, start));
      out += strongOpen ? "</strong>" : `<strong data-struis-mark="${STRUIS_MARK++}">`;
      strongOpen = !strongOpen;
      index = start + match[0].length;
    }
    if (index < s.length) out += escapeHtml(s.slice(index));
    return { html: out, strongOpen };
  }

  function isPureMath(s) {
    return /^[\s\\a-zA-Z0-9Α-Ωα-ω{}()[\]+\-−*/=^_,.<>!|:?'%&#≤≥≠×÷±∞√→←⇒⇔⁰¹²³⁴⁵⁶⁷⁸⁹ⁿ⁺⁻₀₁₂₃₄₅₆₇₈₉ₙ₊₋]+$/.test(s);
  }

  function escapeHtml(s) {
    return String(s || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  // 横にはみ出した数式(D5): 右端を薄くして、続きがあることを示す。端までスクロールしたら薄くしない。
  function markOverflow(el) {
    const overflowing = el.scrollWidth > el.clientWidth + 1;
    el.classList.toggle("struis-overflow", overflowing);
    el.classList.toggle("struis-more", overflowing && el.scrollLeft + el.clientWidth < el.scrollWidth - 1);
    return overflowing;
  }

  function anyOverflow() {
    let result = false;
    document.querySelectorAll(".math-scroll").forEach((el) => {
      if (markOverflow(el)) result = true;
    });
    return result;
  }

  function post(payload) {
    try { window.webkit.messageHandlers.height.postMessage(payload); } catch (e) {}
  }

  function notifyHeight() {
    requestAnimationFrame(() => {
      const root = document.getElementById("root");
      const rect = root.getBoundingClientRect();
      if (rect.width > 0) {
        post({ key: currentKey, width: rect.width, height: Math.ceil(rect.height), overflow: anyOverflow() });
      }
    });
  }

  document.addEventListener("scroll", (event) => {
    const el = event.target;
    if (el && el.classList && el.classList.contains("math-scroll")) markOverflow(el);
  }, { capture: true, passive: true });

  // 本文を入れて配置を決めた後に取る(その本文で使う KaTeX のフォントの読み込みを待つ)。
  function fontsReady() {
    void document.getElementById("root").offsetHeight;
    return document.fonts ? document.fonts.ready : Promise.resolve();
  }
  let observing = false;

  // opts: { source, display, key, color, fontSize, fontWeight, highlight }
  window.struisRender = function (opts) {
    STRUIS_MARK = 0;
    currentKey = opts.key || "";
    const style = document.documentElement.style;
    style.setProperty("--struis-color", opts.color || "inherit");
    style.setProperty("--struis-font-size", String(opts.fontSize || 15) + "px");
    style.setProperty("--struis-font-weight", String(opts.fontWeight || 500));
    const root = document.getElementById("root");
    root.className = "math-expr math-expr--" + (opts.display ? "block" : "inline");
    root.innerHTML = renderMixed(String(opts.source || ""), !!opts.display);
    setStruisHighlight(opts.highlight || 0);
    fontsReady().then(() => {
      post({ loaded: true, key: currentKey });
      notifyHeight();
      if (!observing) {
        observing = true;
        new ResizeObserver(notifyHeight).observe(root);
      }
    });
  };
  window.struisNotifyHeight = function () { fontsReady().then(notifyHeight); };
})();
