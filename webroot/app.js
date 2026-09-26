/* MotoS30侧键魔方 - WebUI 逻辑 (Vanilla JS, 无外部依赖) */
'use strict';

var MODROOT = '/data/adb/modules/xpengsidekey';
var BRIDGE = 'sh ' + MODROOT + '/webroot/bridge.sh';

var PRESETS = [
  { id: 'none',         name: '无操作',            desc: '不执行任何动作',                 cmd: '' },
  { id: 'ringer_cycle', name: '响铃/振动/静音循环', desc: '按 响铃→振动→静音 循环切换',      cmd: 'cmd audio set-ringer-mode …' },
  { id: 'dnd_toggle',   name: '免打扰开关',         desc: '打开/关闭勿扰模式 (DND)',        cmd: 'cmd notification set_dnd …' },
  { id: 'screenshot',   name: '截屏',              desc: '触发系统截屏',                   cmd: 'input keyevent 120' },
  { id: 'wechat_scan',  name: '微信扫一扫',         desc: '直接打开微信扫一扫',              cmd: 'am start -n com.tencent.mm/.plugin.scanner.ui.BaseScanUI' },
  { id: 'wechat_pay',   name: '微信付款码',         desc: '打开微信收付款·付款码',           cmd: 'am start -n com.tencent.mm/com.tencent.mm.plugin.offline.ui.WalletOfflineCoinPurseUI' },
  { id: 'alipay_scan',  name: '支付宝扫一扫',       desc: '打开支付宝扫一扫',                cmd: 'am start -a android.intent.action.VIEW -d "alipays://platformapi/startapp?appId=10000007"' },
  { id: 'alipay_pay',   name: '支付宝付款码',       desc: '打开支付宝付款码',                cmd: 'am start -a android.intent.action.VIEW -d "alipays://platformapi/startapp?appId=20000056"' },
  { id: 'camera',       name: '打开相机',           desc: '启动默认相机应用',                cmd: 'am start -a android.media.action.STILL_IMAGE_CAMERA' },
  { id: 'assistant',    name: '语音助手',           desc: '唤起语音助手',                   cmd: 'am start -a android.intent.action.VOICE_COMMAND' },
  { id: 'custom',       name: '自定义命令',         desc: '为该触发方式单独指定 shell 命令',  cmd: '' }
];

var S = {};          // status 数据
var learnTimer = null;
var statusTimer = null;

/* ================= KernelSU 桥接 ================= */
// 兼容策略（按序）:
//  1) 同步 1 参 exec(cmd) -> stdout 字符串（官方/ReSukiSU 均提供，最可靠）
//  2) 回调 3 参 exec(cmd, options, cb) -> cb(errno, stdout, stderr)（兼容 4 参变体）
//  3) Promise 型 exec 返回值
var KSU = window.ksu || window.__ksu__ || window.KSU || null;
var cbSeq = 0;
var execMode = 'unknown'; // 'sync' | 'callback'

function ksuOk() { return !!(KSU && typeof KSU.exec === 'function'); }

async function trySyncExec(cmd) {
  try {
    var out = KSU.exec(cmd);
    if (typeof out === 'string') {
      return { handled: true, result: { errno: 0, stdout: out, stderr: '' } };
    }
    if (out && typeof out.then === 'function') {
      var v = await Promise.race([out, new Promise(function (res) { setTimeout(function () { res(null); }, 60000); })]);
      if (v === null) return { handled: true, result: { errno: -3, stdout: '', stderr: 'exec promise 超时' } };
      if (typeof v === 'string') return { handled: true, result: { errno: 0, stdout: v, stderr: '' } };
      return { handled: true, result: { errno: Number(v && v.errno) || 0, stdout: (v && v.stdout) || '', stderr: (v && v.stderr) || '' } };
    }
  } catch (e) { /* 同步通道不可用，转回调 */ }
  return { handled: false, result: null };
}

function callbackExec(cmd, timeoutMs) {
  return new Promise(function (res) {
    var done = false;
    var to = setTimeout(function () {
      if (!done) { done = true; res({ errno: -3, stdout: '', stderr: 'exec 回调超时' }); }
    }, timeoutMs || 60000);
    var name = '__xsk_cb_' + (++cbSeq) + '_' + Date.now();
    window[name] = function () {
      if (done) return;
      done = true; clearTimeout(to);
      try { delete window[name]; } catch (e) { window[name] = undefined; }
      var errno, stdout, stderr;
      if (arguments.length >= 4) { errno = arguments[1]; stdout = arguments[2]; stderr = arguments[3]; }
      else { errno = arguments[0]; stdout = arguments[1]; stderr = arguments[2]; }
      res({ errno: Number(errno) || 0, stdout: stdout == null ? '' : String(stdout), stderr: stderr == null ? '' : String(stderr) });
    };
    try { KSU.exec(cmd, '{}', name); }
    catch (e) {
      try { KSU.exec(cmd, name); }
      catch (e2) {
        if (!done) { done = true; clearTimeout(to); res({ errno: -2, stdout: '', stderr: 'exec 调用异常: ' + e2 }); }
      }
    }
  });
}

async function execRaw(cmd, timeoutMs) {
  if (!ksuOk()) return { errno: -1, stdout: '', stderr: '未检测到 ksu 接口，需在 KernelSU 系管理器的 WebUI 中打开' };
  if (execMode !== 'callback') {
    var s = await trySyncExec(cmd);
    if (s.handled) { execMode = 'sync'; return s.result; }
  }
  var r = await callbackExec(cmd, timeoutMs || 60000);
  if (r.errno === 0 || r.errno > 0) execMode = 'callback';
  return r;
}

function b64ToText(b64) {
  try {
    var bin = atob(String(b64 || '').replace(/\s+/g, ''));
    var u = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
    return new TextDecoder('utf-8').decode(u);
  } catch (e) { return ''; }
}
function textToB64(t) {
  var u = new TextEncoder().encode(String(t == null ? '' : t));
  var s = '';
  for (var i = 0; i < u.length; i++) s += String.fromCharCode(u[i]);
  return btoa(s);
}

async function bridge(action, args) {
  var a = (args || []).map(textToB64).join(' ');
  var cmd = BRIDGE + ' ' + action + (a ? ' ' + a : '');
  var r = await execRaw(cmd, 60000);
  if (!r.stdout) {
    // 同步通道拿不到 stderr：用回调通道补一次获取具体错误（仅诊断用途）
    var r2 = await callbackExec(cmd, 60000);
    var detail = ((r2.stderr || r2.stdout || '') + '').trim();
    if (!detail) detail = r.stderr || ('errno ' + r.errno);
    return { ok: false, code: 'EXEC_ERR', data: '', payload: detail };
  }
  var j = null;
  try { j = JSON.parse(r.stdout); } catch (e) { return { ok: false, code: 'BAD_JSON', data: '', payload: r.stdout }; }
  j.payload = b64ToText(j.data || '');
  return j;
}

/* ================= UI 基础 ================= */
function $(id) { return document.getElementById(id); }

function toast(msg) {
  var t = $('toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(t._h);
  t._h = setTimeout(function () { t.classList.remove('show'); }, 2800);
  if (KSU && typeof KSU.toast === 'function') { try { KSU.toast(msg); } catch (e) {} }
}

var modalResolve = null;
function confirmBox(title, body, okText) {
  return new Promise(function (res) {
    modalResolve = res;
    $('modalTitle').textContent = title;
    $('modalBody').textContent = body;
    $('modalOk').textContent = okText || '确定';
    $('modal').classList.remove('hidden');
  });
}
function closeModal(v) {
  $('modal').classList.add('hidden');
  if (modalResolve) { modalResolve(v); modalResolve = null; }
}

function esc(s) {
  return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/* ================= 主题 ================= */
function applyTheme() {
  var t = localStorage.getItem('xsk_theme') || 'auto';
  var dark = t === 'dark' || (t === 'auto' && window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light');
}
$('themeBtn').addEventListener('click', function () {
  var cur = localStorage.getItem('xsk_theme') || 'auto';
  var next = cur === 'dark' ? 'light' : 'dark';
  localStorage.setItem('xsk_theme', next);
  applyTheme();
});
window.matchMedia('(prefers-color-scheme: dark)').addEventListener && window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', applyTheme);

/* ================= 标签页 ================= */
document.querySelectorAll('.tab').forEach(function (btn) {
  btn.addEventListener('click', function () {
    document.querySelectorAll('.tab').forEach(function (b) { b.classList.remove('active'); });
    btn.classList.add('active');
    document.querySelectorAll('.page').forEach(function (p) { p.classList.remove('active'); });
    var pg = $('page-' + btn.dataset.page);
    if (pg) pg.classList.add('active');
    if (btn.dataset.page === 'settings') refreshLog(false);
  });
});

/* ================= 数据渲染 ================= */
function cmdFor(id) {
  if (!id) return '';
  if (id === 'custom') return '';
  var m = /^custom_([1-6])$/.exec(id);
  if (m) return S['custom_' + m[1] + '_cmd'] || '(未设置命令)';
  for (var i = 0; i < PRESETS.length; i++) if (PRESETS[i].id === id) return PRESETS[i].cmd;
  return '(未知功能)';
}
function nameFor(id) {
  if (!id) return '';
  if (id === 'custom') return '自定义命令';
  var m = /^custom_([1-6])$/.exec(id);
  if (m) return S['custom_' + m[1] + '_name'] ? (S['custom_' + m[1] + '_name'] + ' (custom_' + m[1] + ')') : ('未命名 (custom_' + m[1] + ')');
  for (var i = 0; i < PRESETS.length; i++) if (PRESETS[i].id === id) return PRESETS[i].name;
  return id;
}

function bindOptionsHtml() {
  var h = '';
  PRESETS.forEach(function (p) { h += '<option value="' + p.id + '">' + esc(p.name) + '</option>'; });
  for (var n = 1; n <= 6; n++) {
    var nm = S['custom_' + n + '_name'];
    if (nm) h += '<option value="custom_' + n + '">' + esc(nm) + '</option>';
  }
  return h;
}

function renderReadOnly() {
  var on = S.daemon_running === '1';
  var pill = $('statusPill');
  pill.classList.toggle('on', on);
  pill.classList.toggle('off', !on);
  $('statusText').textContent = on ? '守护运行中' : '守护已停止';
  $('daemonState').textContent = on ? 'PID 运行中' : '未运行';

  $('keyInfo').innerHTML =
    '<span class="k">设备</span><span class="v">' + esc(S.key_device_name || '-') + (S.key_device_node ? ' (' + esc(S.key_device_node) + ')' : '') + '</span>' +
    '<span class="k">键值 (scancode)</span><span class="v">' + esc(S.key_scancode || '未设置') + (S.detection_confident === '1' ? ' ✓' : ' ⚠待校准') + '</span>' +
    '<span class="k">源 keylayout</span><span class="v">' + esc(S.kl_source || '-') + (S.kl_source_exists === '0' ? ' (不存在!)' : '') + '</span>' +
    '<span class="k">overlay</span><span class="v">' + esc(S.kl_overlay_rel || '-') + (S.kl_overlay_exists === '1' ? ' (已生成)' : ' (未生成)') + '</span>';

  $('remapInfo').textContent =
    'key ' + (S.key_scancode || '?') + ': ' +
    (S.key_scancode === '217' ? 'SEARCH' : '原始映射') +
    '  ->  ' + (S.remap_label || 'UNKNOWN') +
    (S.remap_enabled === '1' ? '  [启用]' : '  [关闭]');

  $('aVer').textContent = S.version || '-';
  $('aDevice').textContent = (S.device || '-') + ' / ' + (S.release || '-');
  $('aModel').textContent = S.model || '-';
  $('aAndroid').textContent = 'Android ' + (S.release || '-') + ' (SDK ' + (S.sdk || '-') + ')';
  $('aSc').textContent = (S.key_scancode || '-') + ' @ ' + (S.key_device_name || '-');

  var mh = $('metaHint');
  if (mh) mh.classList.toggle('hidden', S.meta_active === '1');
}

function renderBinds() {
  var oh = bindOptionsHtml();
  ['single', 'double', 'long'].forEach(function (t) {
    var sel = $('bind_' + t);
    sel.innerHTML = oh;
    sel.value = S['bind_' + t] || 'none';
    if (sel.selectedIndex < 0) sel.value = 'none';
    var ta = $('ccmd_' + t);
    ta.value = S['custom_' + t + '_cmd'] || '';
    updateBindPreview(t);
  });
}

function updateBindPreview(t) {
  var val = $('bind_' + t).value;
  var ta = $('ccmd_' + t);
  if (val === 'custom') {
    ta.classList.remove('hidden');
    $('prev_' + t).textContent = '$ ' + (ta.value.trim() || '(命令为空)');
  } else {
    ta.classList.add('hidden');
    $('prev_' + t).textContent = cmdFor(val) ? '$ ' + cmdFor(val) : '(无动作)';
  }
}

function renderActions() {
  var h = '';
  PRESETS.forEach(function (p) {
    if (p.id === 'custom') return;
    h += '<div class="preset-item"><div class="nm">' + esc(p.name) + '</div>' +
      '<div class="ds">' + esc(p.desc) + '</div>' +
      (p.cmd ? '<div class="cm">' + esc(p.cmd) + '</div>' : '') + '</div>';
  });
  $('presetList').innerHTML = h;
  renderCustoms();
}

function renderCustoms() {
  var h = '';
  for (var n = 1; n <= 6; n++) {
    var nm = S['custom_' + n + '_name'] || '';
    var cm = S['custom_' + n + '_cmd'] || '';
    if (!nm && !cm) continue;
    h += '<div class="custom-item" data-n="' + n + '">' +
      '<div class="nm">custom_' + n + '</div>' +
      '<input class="cname" maxlength="24" value="' + esc(nm) + '" placeholder="功能名称">' +
      '<input class="ccmd mono" value="' + esc(cm) + '" placeholder="shell 命令">' +
      '<div class="row end"><button class="btn tonal sm csave" data-n="' + n + '">保存</button>' +
      '<button class="btn text sm danger cdel" data-n="' + n + '">删除</button></div></div>';
  }
  $('customList').innerHTML = h || '<p class="hint">暂无自定义功能，点击右上角「添加」创建。</p>';

  document.querySelectorAll('.csave').forEach(function (b) {
    b.addEventListener('click', async function () {
      var item = b.closest('.custom-item');
      var n = b.dataset.n;
      var nm = item.querySelector('.cname').value.trim();
      var cm = item.querySelector('.ccmd').value.trim();
      if (!nm) { toast('名称不能为空'); return; }
      var r = await bridge('save_custom', [n, nm, cm]);
      toast(r.ok ? '已保存 custom_' + n : ('保存失败: ' + (r.payload || r.code)));
      loadStatus();
    });
  });
  document.querySelectorAll('.cdel').forEach(function (b) {
    b.addEventListener('click', async function () {
      if (!(await confirmBox('删除自定义功能', '确定删除 custom_' + b.dataset.n + ' 吗？'))) return;
      var r = await bridge('del_custom', [b.dataset.n]);
      toast(r.ok ? '已删除' : ('删除失败: ' + (r.payload || r.code)));
      loadStatus();
    });
  });
}

/* ================= 状态加载 ================= */
function parseStatus(p) {
  var m = {};
  String(p || '').split('\n').forEach(function (l) {
    var i = l.indexOf('=');
    if (i > 0) m[l.slice(0, i)] = l.slice(i + 1);
  });
  return m;
}

function applyStatus() {
  renderReadOnly();
  renderBinds();
  renderActions();
  $('remapSwitch').checked = S.remap_enabled === '1';
  $('remapLabel').value = S.remap_label || 'UNKNOWN';
  $('swEnabled').checked = S.enabled === '1';
  $('swHaptic').checked = S.haptic === '1';
  $('rngGap').value = S.click_gap_ms || 300;
  $('gapVal').textContent = S.click_gap_ms || 300;
  $('rngLong').value = S.long_press_ms || 550;
  $('longVal').textContent = S.long_press_ms || 550;
}

async function loadStatus() {
  var r = await bridge('status');
  if (!r.ok) {
    var b = $('noKsu');
    b.textContent = 'WebUI 通信失败: ' + (r.payload || r.code) + ' —— 请完全退出并重开管理器重试；若仍失败，请将本行文字反馈给开发者';
    b.classList.remove('hidden');
    $('statusText').textContent = '通信失败';
    return;
  }
  S = parseStatus(r.payload);
  try { localStorage.setItem('xsk_status', r.payload); } catch (e) {}
  applyStatus();
}

/* ================= 学习按键 ================= */
$('learnBtn').addEventListener('click', async function () {
  var r = await bridge('learn_start');
  if (!r.ok) { toast('启动学习失败'); return; }
  $('learnBox').classList.remove('hidden');
  $('learnSave').disabled = true;
  $('learnResult').value = '';
  var left = 12;
  $('learnCount').textContent = left;
  clearInterval(learnTimer);
  learnTimer = setInterval(async function () {
    left--;
    $('learnCount').textContent = Math.max(left, 0);
    var lr = await bridge('learn_result');
    if (lr.ok && /^\d+/.test(lr.payload.trim())) {
      finishLearn(lr.payload.trim());
    } else if (left <= 0) {
      clearInterval(learnTimer);
      learnTimer = null;
      $('learnHint').textContent = lr.payload && lr.payload.indexOf('running') === 0 ? '学习仍在进行…' : '未捕获按键，请重试';
      if (!lr.payload || lr.payload.indexOf('running') !== 0) $('learnBox').classList.add('hidden');
    }
  }, 1000);
});

function finishLearn(payload) {
  clearInterval(learnTimer);
  learnTimer = null;
  var parts = payload.split(/\s+/);
  var sc = parts[0], node = parts[1] || '';
  $('learnResult').value = 'scancode=' + sc + (node ? '  node=' + node : '');
  $('learnResult').dataset.sc = sc;
  $('learnResult').dataset.node = node;
  $('learnSave').disabled = false;
  $('learnHint').textContent = '已捕获，点击保存键值';
}

$('learnSave').addEventListener('click', async function () {
  var sc = $('learnResult').dataset.sc;
  var node = $('learnResult').dataset.node || '';
  if (!sc) return;
  var r = await bridge('save_key', [sc, node, '']);
  toast(r.ok ? (r.payload || '已保存') : ('保存失败: ' + (r.payload || r.code)));
  $('learnBox').classList.add('hidden');
  loadStatus();
});
$('learnCancel').addEventListener('click', function () {
  clearInterval(learnTimer); learnTimer = null;
  bridge('learn_cancel');
  $('learnBox').classList.add('hidden');
});

/* ================= 绑定 ================= */
['single', 'double', 'long'].forEach(function (t) {
  $('bind_' + t).addEventListener('change', function () { updateBindPreview(t); });
  $('ccmd_' + t).addEventListener('input', function () {
    if ($('bind_' + t).value === 'custom') $('prev_' + t).textContent = '$ ' + ($('ccmd_' + t).value.trim() || '(命令为空)');
  });
});

$('saveBindsBtn').addEventListener('click', async function () {
  var errs = 0;
  for (var i = 0; i < 3; i++) {
    var t = ['single', 'double', 'long'][i];
    var val = $('bind_' + t).value;
    var r1 = await bridge('bind', [t, val]);
    if (!r1.ok) errs++;
    if (val === 'custom') {
      var cm = $('ccmd_' + t).value.trim();
      if (!cm) { toast('「' + t + '」自定义命令为空'); errs++; continue; }
      var r2 = await bridge('set_custom_cmd', [t, cm]);
      if (!r2.ok) errs++;
    }
  }
  toast(errs ? ('保存失败 (' + errs + ' 项)') : '绑定已保存并即时生效');
  if (!errs) loadStatus();
});

document.querySelectorAll('.testbtn').forEach(function (b) {
  b.addEventListener('click', async function () {
    var t = b.dataset.t;
    var val = $('bind_' + t).value;
    var nm = nameFor(val);
    var extra = '';
    if (val === 'custom') extra = $('ccmd_' + t).value.trim();
    if (!(await confirmBox('测试执行', '立即执行「' + nm + '」？\n\n该操作等同按下侧键触发，敏感命令请确认。', '执行'))) return;
    b.disabled = true;
    var r = await bridge('test_action', [val, extra]);
    b.disabled = false;
    confirmBox('执行结果 (' + (r.ok ? '已提交' : '失败') + ')', r.payload || r.code, '关闭');
  });
});

/* ================= 键位映射 ================= */
$('remapSwitch').addEventListener('change', async function () {
  var v = $('remapSwitch').checked ? '1' : '0';
  var r = await bridge('set_conf', ['remap_enabled', v]);
  var r2 = await bridge('apply_kl');
  toast(r.ok && r2.ok ? (r2.payload || '已应用，重启后生效') : '操作失败');
  loadStatus();
});
$('applyKlBtn').addEventListener('click', async function () {
  var label = $('remapLabel').value.trim() || 'UNKNOWN';
  if (!(await confirmBox('应用键位映射', '将侧键映射为 ' + label + '，重启手机后生效。继续？'))) return;
  var r = await bridge('set_remap_label', [label]);
  toast(r.ok ? (r.payload || '已应用') : ('失败: ' + (r.payload || r.code)));
  loadStatus();
});

/* ================= 设置 ================= */
$('swEnabled').addEventListener('change', async function () {
  var r = await bridge('daemon', [$('swEnabled').checked ? 'start' : 'stop']);
  toast(r.ok ? (r.payload || '已切换') : '操作失败');
  loadStatus();
});
$('btnRestartDaemon').addEventListener('click', async function () {
  await bridge('set_conf', ['enabled', '1']);
  var r = await bridge('daemon', ['restart']);
  toast(r.ok ? (r.payload || '已重启') : '重启失败');
  loadStatus();
});
$('btnStopDaemon').addEventListener('click', async function () {
  var r = await bridge('daemon', ['stop']);
  toast(r.ok ? (r.payload || '已停止') : '操作失败');
  loadStatus();
});
$('rngGap').addEventListener('input', function () { $('gapVal').textContent = $('rngGap').value; });
$('rngLong').addEventListener('input', function () { $('longVal').textContent = $('rngLong').value; });
$('saveSettingsBtn').addEventListener('click', async function () {
  var gap = parseInt($('rngGap').value, 10), lng = parseInt($('rngLong').value, 10);
  if (lng <= gap) { toast('长按时间应大于单击间隔'); return; }
  var r = await bridge('set_conf', [
    'haptic', $('swHaptic').checked ? '1' : '0',
    'click_gap_ms', String(gap),
    'long_press_ms', String(lng)
  ]);
  toast(r.ok ? '设置已保存' : '保存失败');
  loadStatus();
});

/* ================= 日志 ================= */
async function refreshLog(showToast) {
  var r = await bridge('log', ['12000']);
  if (r.ok) {
    $('logView').textContent = r.payload || '(空)';
    $('logView').scrollTop = $('logView').scrollHeight;
    if (showToast) toast('日志已刷新');
  }
}
$('btnLogRefresh').addEventListener('click', function () { refreshLog(true); });
$('btnLogClear').addEventListener('click', async function () {
  if (!(await confirmBox('清空日志', '确定清空模块日志吗？'))) return;
  await bridge('clear_log');
  refreshLog(false);
  toast('日志已清空');
});

/* ================= 配置备份 ================= */
$('btnExport').addEventListener('click', async function () {
  var r = await bridge('export_conf');
  if (r.ok) { $('cfgArea').value = r.payload; toast('已导出到文本框，请复制保存'); }
  else toast('导出失败');
});
$('btnCopyCfg').addEventListener('click', async function () {
  var txt = $('cfgArea').value;
  if (!txt) { toast('请先导出配置'); return; }
  try { await navigator.clipboard.writeText(txt); toast('已复制到剪贴板'); }
  catch (e) {
    $('cfgArea').select();
    document.execCommand && document.execCommand('copy');
    toast('已尝试复制，请手动检查');
  }
});
$('btnImport').addEventListener('click', async function () {
  var txt = $('cfgArea').value.trim();
  if (!txt) { toast('请先粘贴配置文本'); return; }
  if (!(await confirmBox('导入配置', '导入将覆盖当前绑定/时序等设置，继续？'))) return;
  var r = await bridge('import_conf', [txt]);
  toast(r.ok ? (r.payload || '已导入') : ('导入失败: ' + (r.payload || r.code)));
  loadStatus();
});
$('cfgFile').addEventListener('change', function () {
  var f = $('cfgFile').files[0];
  if (!f) return;
  var rd = new FileReader();
  rd.onload = function () { $('cfgArea').value = rd.result; toast('文件已读取，点击「导入」应用'); };
  rd.readAsText(f);
});
$('btnResetCfg').addEventListener('click', async function () {
  if (!(await confirmBox('恢复默认', '绑定/时序/反馈将恢复默认值（保留按键识别与自定义功能）。继续？', '恢复'))) return;
  var r = await bridge('reset_conf');
  toast(r.ok ? (r.payload || '已恢复默认') : '操作失败');
  loadStatus();
});

/* ================= 自定义功能添加 ================= */
$('addCustomBtn').addEventListener('click', function () {
  if ($('customList').querySelector('.custom-item.new')) return;
  var div = document.createElement('div');
  div.className = 'custom-item new';
  div.innerHTML = '<div class="nm">新建自定义功能</div>' +
    '<input class="cname" maxlength="24" placeholder="功能名称 (字母/数字)">' +
    '<input class="ccmd mono" placeholder="shell 命令">' +
    '<div class="row end"><button class="btn text sm cnc">取消</button>' +
    '<button class="btn filled sm cok">创建</button></div>';
  $('customList').prepend(div);
  div.querySelector('.cnc').addEventListener('click', function () { div.remove(); renderCustoms(); });
  div.querySelector('.cok').addEventListener('click', async function () {
    var nm = div.querySelector('.cname').value.trim();
    var cm = div.querySelector('.ccmd').value.trim();
    if (!nm) { toast('名称不能为空'); return; }
    var r = await bridge('add_custom', [nm, cm]);
    toast(r.ok ? '已创建 ' + r.payload : ('创建失败: ' + (r.payload || r.code)));
    loadStatus();
  });
});

/* ================= 诊断 ================= */
$('btnDiagnose').addEventListener('click', async function () {
  $('diagOut').textContent = '诊断运行中…';
  var r = await bridge('diagnose', null);
  $('diagOut').textContent = (r.ok ? r.payload : ('失败: ' + (r.payload || r.code))) || '(无输出)';
});
$('btnCopyDiag').addEventListener('click', async function () {
  try { await navigator.clipboard.writeText($('diagOut').textContent); toast('已复制'); }
  catch (e) { toast('复制失败，请长按文本手动复制'); }
});

/* ================= 弹窗 ================= */
$('modalOk').addEventListener('click', function () { closeModal(true); });
$('modalCancel').addEventListener('click', function () { closeModal(false); });

/* ================= 启动 ================= */
applyTheme();
if (!KSU || typeof KSU.exec !== 'function') {
  $('noKsu').classList.remove('hidden');
} else {
  // 秒开：先用上次缓存渲染界面，桥就绪后再刷新真实数据
  var cached = null;
  try { cached = localStorage.getItem('xsk_status'); } catch (e) {}
  if (cached) { S = parseStatus(cached); applyStatus(); }
}
loadStatus();
statusTimer = setInterval(function () {
  bridge('status').then(function (r) {
    if (!r.ok) return;
    var map = {};
    r.payload.split('\n').forEach(function (l) {
      var i = l.indexOf('=');
      if (i > 0) map[l.slice(0, i)] = l.slice(i + 1);
    });
    var on = map.daemon_running === '1';
    var pill = $('statusPill');
    pill.classList.toggle('on', on);
    pill.classList.toggle('off', !on);
    $('statusText').textContent = on ? '守护运行中' : '守护已停止';
    $('daemonState').textContent = on ? 'PID 运行中' : '未运行';
  });
}, 20000);
