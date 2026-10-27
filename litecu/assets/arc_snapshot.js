JSON.stringify((P => {
  const visible = e => {
    const r = e.getBoundingClientRect(), s = getComputedStyle(e);
    return r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 &&
      r.top < innerHeight && r.left < innerWidth && s.visibility !== 'hidden' &&
      s.visibility !== 'collapse' && s.display !== 'none' && Number(s.opacity) > 0;
  };
  const name = e => (e.getAttribute('aria-label') || e.labels?.[0]?.innerText ||
    e.innerText || e.getAttribute('placeholder') || e.getAttribute('title') || '').trim().slice(0, 180);
  const nodes = Array.from(document.querySelectorAll(
    'a[href],button,input,textarea,select,[role="button"],[role="link"],[contenteditable="true"]'
  )).filter(visible).slice(0, 180);
  const refs = new Map();
  const elements = nodes.map((e, i) => {
    const id = P.token + ':' + i, label = name(e);
    refs.set(id, {element: e, label, tag: e.tagName, href: e.tagName === 'A' ? e.href : '', type: e.type || ''});
    return {id, role: e.getAttribute('role') || e.tagName.toLowerCase(), name: label,
      type: e.getAttribute('type'), disabled: !!e.disabled,
      href: e.tagName === 'A' ? e.href : undefined,
      value: ['password', 'hidden'].includes(e.type) ? undefined : String(e.value || '').slice(0, 240)};
  });
  window[P.key] = {token: P.token, refs, url: location.href, name};
  return {ok: true, title: document.title, url: location.href,
    text: (document.body?.innerText || '').slice(0, 16000), elements,
    limitations: 'Visible top-level DOM only; no iframe, canvas, native controls or trusted input.'};
})(__LITECU_PARAMETERS__))
