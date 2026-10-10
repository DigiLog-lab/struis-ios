import Foundation

/// バンドル同梱のシーンパッケージサンプル。
/// アセット登録を避けるため meta.json / scene.html を Swift 文字列リテラルで持つ
/// (手動 file reference 式の pbxproj で Resources フェーズを触らないため)。
enum BundledScenes {
    static let samples: [ScenePackage] = [icedTeaDilution]

    /// iced-tea-dilution — 反比例 (全体量が増えると濃さは薄まる)。
    static let icedTeaDilution: ScenePackage = {
        // リテラルが壊れている場合は DEBUG プロトタイプなので即座に気づけるよう落とす。
        let meta = try! JSONDecoder().decode(SceneMeta.self, from: Data(icedTeaMetaJSON.utf8))
        return ScenePackage(meta: meta, sceneHTML: icedTeaSceneHTML)
    }()
}

// MARK: - meta.json (契約 §2)

private let icedTeaMetaJSON = #"""
{
  "id": "iced-tea-dilution",
  "version": 1,
  "kernel": "全体量が増えると、混ざったものの濃さは薄まる",
  "misconception": "氷が溶けても甘さは変わらないと思う",
  "grade": "中学1年",
  "source_label": "さっきの アイスティー",
  "unit": "%",
  "hook": { "headline": "氷を入れた アイスティー、10 分後の甘さは?", "sub": "氷が少しずつ溶けています。" },
  "model": {
    "kind": "inverse_relation",
    "parameters": { "constant": 100, "input_min": 200, "input_max": 400 },
    "checks": [ { "input": 200, "expect": 50 }, { "input": 400, "expect": 25 } ]
  },
  "consequence": { "template": "予想との差は {gap}。氷が水に変わって、全体量が増えたから。" },
  "insight": { "serif": "混ざったものは、全体が増えると薄まる。", "note": "甘さの量は変わっていない。分母が増えた。" },
  "retry": {
    "question": "氷が全部溶けて 2 倍の量になったら、甘さは?",
    "choices": ["同じ", "半分", "2 倍"],
    "answer_index": 1,
    "success_line": "分母が 2 倍なら、濃さは半分。読めましたね。"
  },
  "transfer": {
    "question": "カレーのルーの量はそのままで、水を 2 倍にすると、辛さはどうなる?",
    "note": "紙とペンがあれば、そちらで考えるのがおすすめです。",
    "answer_kind": "text",
    "answer": "半分になる",
    "feedback_ok": "同じ形が使えました。「全体が増えると薄まる」が使えています。",
    "feedback_retry": "止まらずに。「増えたのはルー? それとも水分?」と分母を見てみて。"
  },
  "boundary": { "summary_serif": "分母を見れば、濃さは読める。", "summary_line": "予想 → 動かす → 比較 → 圧縮。ひとつの循環が閉じました。" },
  "hint": "甘さそのものは減っていない。増えたのは何?",
  "copy_guard_forbidden": ["問題", "正解", "解説", "テスト", "単元", "解答"]
}
"""#

// MARK: - scene.html (契約 §3-4。predict / explore / consequence の3ステージを描く自己完結シーン)

private let icedTeaSceneHTML = #"""
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
:root {
  --accent: #b8733a;
  --accent-soft: rgba(184,115,58,0.14);
  --growth: #3f8f62;
  --text-primary: #1f1a14;
  --text-secondary: #5a5044;
  --text-tertiary: #8a7f6f;
  --font-sans: -apple-system, 'Hiragino Sans', sans-serif;
  --font-serif: 'HiraMinProN-W6', 'YuMincho', serif;
}
html, body {
  margin: 0;
  padding: 0;
  background: transparent;
  touch-action: manipulation;
  overscroll-behavior: none;
  font-family: var(--font-sans);
  color: var(--text-primary);
  -webkit-user-select: none;
  user-select: none;
  -webkit-tap-highlight-color: transparent;
}
#app { padding: 10px 12px 6px; }
#guide { font-size: 13px; color: var(--text-secondary); margin: 0 2px 6px; }
#world { display: block; margin: 0 auto; max-width: 360px; }
#controls { margin: 6px 8px 0; min-height: 28px; }
#controls input[type="range"] { width: 100%; accent-color: var(--accent); margin: 2px 0 0; }
#readout { text-align: center; margin-top: 4px; min-height: 26px; font-size: 12px; color: var(--text-secondary); }
#readout .serif { font-family: var(--font-serif); font-size: 22px; color: var(--accent); padding: 0 2px; }
#interp {
  margin: 8px 4px 2px;
  font-size: 12px;
  line-height: 1.6;
  color: var(--text-primary);
  background: var(--accent-soft);
  border-radius: 14px;
  padding: 10px 14px;
  display: none;
}
.tag { font-size: 10px; fill: var(--text-secondary); }
.tag-accent { fill: var(--accent); }
.tag-growth { fill: var(--growth); }
body.motion #liquid, body.motion #iceG { transition: all 0.25s ease; }
</style>
</head>
<body>
<div id="app">
  <div id="guide"></div>
  <svg id="world" viewBox="0 0 360 215">
    <defs>
      <clipPath id="glassClip"><rect x="33" y="22" width="74" height="166" rx="10"/></clipPath>
    </defs>

    <g clip-path="url(#glassClip)">
      <rect id="liquid" x="33" y="105" width="74" height="83" fill="rgba(184,115,58,0.6)"/>
      <g id="iceG">
        <rect x="-13" y="-13" width="26" height="26" rx="7" fill="rgba(255,255,255,0.82)" stroke="rgba(255,255,255,0.95)" stroke-width="1"/>
        <rect x="12" y="-4" width="20" height="20" rx="6" fill="rgba(255,255,255,0.7)" stroke="rgba(255,255,255,0.9)" stroke-width="1"/>
      </g>
    </g>
    <rect x="30" y="18" width="80" height="174" rx="13" fill="none" stroke="rgba(90,80,68,0.4)" stroke-width="1.6"/>
    <text x="70" y="208" text-anchor="middle" class="tag">氷の入った アイスティー</text>

    <g id="gauge">
      <text x="190" y="12" text-anchor="middle" class="tag">濃さ (%)</text>
      <rect x="182" y="18" width="16" height="174" rx="8" fill="rgba(90,80,68,0.10)"/>
      <rect id="gaugeFill" x="182" y="18" width="16" height="0" rx="8" fill="var(--accent)" opacity="0.25" visibility="hidden"/>
      <g font-size="9" fill="var(--text-tertiary)">
        <text x="174" y="195" text-anchor="end">0</text>
        <text x="174" y="123" text-anchor="end">25</text>
        <text x="174" y="50" text-anchor="end">50</text>
      </g>
      <g id="markNow" visibility="hidden">
        <line x1="178" x2="226" y1="0" y2="0" stroke="var(--text-tertiary)" stroke-width="1.4"/>
        <text x="230" y="3" class="tag"></text>
      </g>
      <g id="markGhost" visibility="hidden">
        <line x1="176" x2="206" y1="0" y2="0" stroke="var(--text-tertiary)" stroke-width="1.2" stroke-dasharray="4 3" opacity="0.6"/>
        <text x="210" y="3" class="tag">さっきの予想</text>
      </g>
      <g id="markPred" visibility="hidden">
        <line x1="172" x2="222" y1="0" y2="0" stroke="var(--accent)" stroke-width="1.8" stroke-dasharray="6 4"/>
        <circle cx="190" cy="0" r="9" fill="var(--accent)"/>
        <text x="226" y="3" class="tag tag-accent"></text>
      </g>
      <g id="markActual" visibility="hidden">
        <line x1="172" x2="222" y1="0" y2="0" stroke="var(--accent)" stroke-width="3"/>
        <text x="226" y="3" class="tag tag-accent">実際</text>
      </g>
      <g id="gapBracket" visibility="hidden">
        <path id="bracketPath" d="" fill="none" stroke="var(--growth)" stroke-width="2"/>
        <text id="gapLabel" x="156" y="0" text-anchor="end" class="tag tag-growth"></text>
      </g>
    </g>
    <rect id="gaugeTouch" x="160" y="10" width="170" height="195" fill="transparent"/>
  </svg>
  <div id="controls"></div>
  <div id="readout"></div>
  <div id="interp"></div>
</div>
<script>
(function () {
  var S = window.struis || {};
  var tokens = S.tokens || {};
  var root = document.documentElement;
  function setVar(name, key) { if (tokens[key]) root.style.setProperty(name, tokens[key]); }
  setVar('--accent', 'accent');
  setVar('--accent-soft', 'accentSoft');
  setVar('--growth', 'growth');
  setVar('--text-primary', 'textPrimary');
  setVar('--text-secondary', 'textSecondary');
  setVar('--text-tertiary', 'textTertiary');
  setVar('--font-sans', 'fontSans');
  setVar('--font-serif', 'fontSerif');
  if (!(S.capabilities && S.capabilities.reduceMotion)) document.body.classList.add('motion');

  var params = (S.model && S.model.parameters) || { constant: 100, input_min: 200, input_max: 400 };
  var constant = Number(params.constant) || 100;
  var x0 = Number(params.input_min) || 200;
  var x1 = Number(params.input_max) || 400;
  var T_MAX = 10;
  var GAUGE_MAX = 60;

  function amountAt(t) { return x0 + (x1 - x0) * (t / T_MAX); }
  // checks (input 200 → 50, input 400 → 25) に合わせ、% 単位で評価する (constant / x は分数)。
  function concAt(t) { return 100 * constant / amountAt(t); }
  function round1(v) { return Math.round(v * 10) / 10; }
  function fmt(v) { var r = round1(v); return (r === Math.floor(r)) ? String(Math.floor(r)) : String(r); }
  function post(type, payload) { if (S.post) S.post(type, payload); }

  var state = { stage: 'predict', prediction: null, ghost: null, t: 0 };

  function $(id) { return document.getElementById(id); }
  var guide = $('guide'), controls = $('controls'), readout = $('readout'), interp = $('interp');
  var liquid = $('liquid'), iceG = $('iceG'), gaugeFill = $('gaugeFill');
  var markNow = $('markNow'), markGhost = $('markGhost'), markPred = $('markPred');
  var markActual = $('markActual'), gapBracket = $('gapBracket');

  var G_TOP = 18, G_BOTTOM = 192, G_H = G_BOTTOM - G_TOP;
  function gy(v) { return G_BOTTOM - (Math.max(0, Math.min(GAUGE_MAX, v)) / GAUGE_MAX) * G_H; }
  function placeMark(g, v) { g.setAttribute('transform', 'translate(0,' + gy(v) + ')'); }

  var INNER_BOTTOM = 188, INNER_H = 166;
  function renderGlass() {
    var x = amountAt(state.t);
    var conc = concAt(state.t);
    var fill = 0.5 + 0.38 * ((x - x0) / (x1 - x0));
    var h = INNER_H * fill;
    var y = INNER_BOTTOM - h;
    liquid.setAttribute('y', String(y));
    liquid.setAttribute('height', String(h));
    liquid.setAttribute('fill', 'rgba(184,115,58,' + (0.18 + 0.62 * (conc / GAUGE_MAX)).toFixed(3) + ')');
    var ice = (x1 - x) / (x1 - x0);
    if (ice < 0.04) {
      iceG.setAttribute('visibility', 'hidden');
    } else {
      iceG.setAttribute('visibility', 'visible');
      var s = 0.35 + 0.65 * ice;
      iceG.setAttribute('transform', 'translate(70,' + (y + 16) + ') scale(' + s.toFixed(3) + ')');
    }
  }

  function renderGauge() {
    var stage = state.stage;
    var conc = concAt(state.t);
    if (stage === 'explore') {
      gaugeFill.setAttribute('y', String(gy(conc)));
      gaugeFill.setAttribute('height', String(Math.max(0, G_BOTTOM - gy(conc))));
      gaugeFill.setAttribute('visibility', 'visible');
      placeMark(markNow, conc);
      markNow.querySelector('text').textContent = 'いま ' + fmt(conc) + '%';
      markNow.setAttribute('visibility', 'visible');
    } else if (stage === 'predict') {
      gaugeFill.setAttribute('visibility', 'hidden');
      placeMark(markNow, concAt(0));
      markNow.querySelector('text').textContent = 'いま ' + fmt(concAt(0)) + '%';
      markNow.setAttribute('visibility', 'visible');
    } else {
      gaugeFill.setAttribute('visibility', 'hidden');
      markNow.setAttribute('visibility', 'hidden');
    }
    if (stage === 'predict' && state.ghost != null) {
      placeMark(markGhost, state.ghost);
      markGhost.setAttribute('visibility', 'visible');
    } else {
      markGhost.setAttribute('visibility', 'hidden');
    }
    if (state.prediction != null) {
      placeMark(markPred, state.prediction);
      markPred.querySelector('text').textContent =
        stage === 'consequence' ? 'あなたの予想 ' + fmt(state.prediction) + '%' : fmt(state.prediction) + '%';
      markPred.setAttribute('visibility', 'visible');
    } else {
      markPred.setAttribute('visibility', 'hidden');
    }
    if (stage === 'consequence') {
      var actual = concAt(T_MAX);
      placeMark(markActual, actual);
      markActual.setAttribute('visibility', 'visible');
      if (state.prediction != null && Math.abs(state.prediction - actual) > 0.5) {
        var y1 = gy(state.prediction), y2 = gy(actual);
        var top = Math.min(y1, y2), h = Math.abs(y1 - y2);
        $('bracketPath').setAttribute('d', 'M 168 ' + y1 + ' L 160 ' + y1 + ' L 160 ' + y2 + ' L 168 ' + y2);
        var label = $('gapLabel');
        label.setAttribute('y', String(top + h / 2 + 3));
        label.textContent = '差 ' + fmt(Math.abs(state.prediction - actual)) + '%';
        gapBracket.setAttribute('visibility', 'visible');
      } else {
        gapBracket.setAttribute('visibility', 'hidden');
      }
    } else {
      markActual.setAttribute('visibility', 'hidden');
      gapBracket.setAttribute('visibility', 'hidden');
    }
  }

  function renderControls() {
    if (state.stage === 'explore') {
      controls.innerHTML = '<input id="timeSlider" type="range" min="0" max="10" step="0.5" value="' + state.t + '">';
      $('timeSlider').addEventListener('input', function () {
        state.t = parseFloat(this.value);
        renderGlass();
        renderGauge();
        renderReadout();
      });
    } else {
      controls.innerHTML = '';
    }
  }

  function renderReadout() {
    if (state.stage === 'explore') {
      readout.innerHTML = '<span class="serif">' + fmt(state.t) + '</span> 分 → 濃さ <span class="serif">' + fmt(concAt(state.t)) + '</span>%';
    } else if (state.stage === 'predict' && state.ghost != null) {
      readout.textContent = '薄い破線は、さっきの予想。';
    } else {
      readout.textContent = '';
    }
  }

  function renderInterp() {
    if (state.stage !== 'consequence') {
      interp.style.display = 'none';
      return;
    }
    var actual = concAt(T_MAX);
    var text;
    if (state.prediction == null) {
      text = '氷が水に変わって、全体量が増えた。濃さは ' + fmt(actual) + '%。';
    } else {
      var gap = state.prediction - actual;
      if (gap > 0.5) {
        text = '予想より ' + fmt(gap) + '% 薄い。氷が水に変わって、全体量が増えたから。';
      } else if (gap < -0.5) {
        text = '予想より ' + fmt(-gap) + '% 濃い。溶けた氷ぶん、全体量が増えている。';
      } else {
        text = 'ぴったり。氷が水に変わって、全体量が増えた。';
      }
    }
    interp.textContent = text;
    interp.style.display = 'block';
  }

  function render() {
    if (state.stage === 'predict') {
      guide.textContent = 'ゲージをドラッグして、10 分後の甘さ (濃さ) を予想して。';
    } else if (state.stage === 'explore') {
      guide.textContent = '時間を動かして。氷が溶けると、グラスの中身はどうなる?';
    } else {
      guide.textContent = '破線があなたの予想、実線が実際。';
    }
    renderGlass();
    renderGauge();
    renderControls();
    renderReadout();
    renderInterp();
  }

  // --- 予想の直接操作 (ドラッグで置く、離して commit) ---
  var dragging = false;
  var touch = $('gaugeTouch');
  var svg = $('world');
  function valueFromEvent(e) {
    var ctm = svg.getScreenCTM();
    if (!ctm) return state.prediction;
    var pt = svg.createSVGPoint();
    pt.x = e.clientX;
    pt.y = e.clientY;
    var p = pt.matrixTransform(ctm.inverse());
    var v = (G_BOTTOM - p.y) / G_H * GAUGE_MAX;
    return Math.max(0, Math.min(GAUGE_MAX, round1(v)));
  }
  touch.addEventListener('pointerdown', function (e) {
    if (state.stage !== 'predict') return;
    dragging = true;
    state.prediction = valueFromEvent(e);
    renderGauge();
    if (touch.setPointerCapture && e.pointerId != null) {
      try { touch.setPointerCapture(e.pointerId); } catch (err) {}
    }
    e.preventDefault();
  });
  touch.addEventListener('pointermove', function (e) {
    if (!dragging || state.stage !== 'predict') return;
    state.prediction = valueFromEvent(e);
    renderGauge();
    e.preventDefault();
  });
  function endDrag() {
    if (!dragging) return;
    dragging = false;
    if (state.stage === 'predict' && state.prediction != null) {
      post('prediction', { value: state.prediction });
    }
  }
  touch.addEventListener('pointerup', endDrag);
  touch.addEventListener('pointercancel', endDrag);

  // --- ブリッジ契約 §4.1 ---
  window.struisScene = {
    enterStage: function (stage, context) {
      var prevStage = state.stage;
      if (stage === 'predict') {
        // 前回の予想はゴースト (薄い破線) として残す。予想は資産。
        if (prevStage !== 'predict' && state.prediction != null) state.ghost = state.prediction;
        state.prediction = null;
        state.t = 0;
      }
      state.stage = stage;
      if (stage === 'consequence' && context && context.prediction != null) {
        var p = Number(context.prediction);
        if (!isNaN(p)) state.prediction = p;
      }
      render();
    },
    snapshot: function () {
      return { stage: state.stage, prediction: state.prediction, ghost: state.ghost, t: state.t };
    },
    restore: function (s) {
      if (s) {
        state.stage = s.stage || 'predict';
        state.prediction = (s.prediction != null) ? s.prediction : null;
        state.ghost = (s.ghost != null) ? s.ghost : null;
        state.t = s.t || 0;
      }
      render();
    }
  };

  render();
  post('ready');
  post('log', { level: 'info', message: 'scene ready: iced-tea-dilution' });
})();
</script>
</body>
</html>
"""#
