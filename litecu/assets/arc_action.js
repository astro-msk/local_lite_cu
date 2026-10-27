JSON.stringify((P => {
  let dispatched = false;
  const stale = message => { throw Object.assign(new Error(message), {kind: 'stale'}); };
  try {
    const s = window[P.key], a = P.arguments, action = P.name;
    if (!s || s.token !== P.token || s.url !== location.href)
      stale('Page changed; observe again before acting.');
    if (action === 'browser_scroll') {
      const d = a.direction, amount = a.amount * 300;
      dispatched = true;
      window.scrollBy({left: d === 'left' ? -amount : d === 'right' ? amount : 0,
        top: d === 'up' ? -amount : d === 'down' ? amount : 0, behavior: 'instant'});
      return {ok: true, message: 'Scrolled the task page; verify the next observation.'};
    }
    const ref = s.refs.get(a.element_id), e = ref?.element;
    if (!e || !e.isConnected || s.name(e) !== ref.label || e.tagName !== ref.tag ||
        (e.tagName === 'A' ? e.href : '') !== ref.href || (e.type || '') !== ref.type)
      stale('Target changed; observe again before acting.');
    const r = e.getBoundingClientRect(), style = getComputedStyle(e);
    if (e.disabled || r.width <= 0 || r.height <= 0 || r.bottom <= 0 || r.right <= 0 ||
        r.top >= innerHeight || r.left >= innerWidth || style.visibility === 'hidden' ||
        style.visibility === 'collapse' || style.display === 'none' || Number(style.opacity) <= 0)
      stale('Target is no longer available in the observed view.');
    if (e.tagName === 'INPUT' && ['password', 'file', 'hidden'].includes(e.type))
      throw new Error('This input requires you to handle it directly.');
    if (action === 'browser_click') {
      if (e.tagName === 'A') {
        const url = new URL(e.href, location.href);
        if (!/^https?:$/.test(url.protocol) || url.username || url.password)
          throw new Error('Only HTTP/HTTPS links without embedded credentials are supported.');
        if (e.target && e.target !== '_self')
          throw new Error('This link opens another tab. Use open_url with its observed HTTP/HTTPS address.');
      }
      const x = (Math.max(0, r.left) + Math.min(innerWidth, r.right)) / 2;
      const y = (Math.max(0, r.top) + Math.min(innerHeight, r.bottom)) / 2;
      const hit = document.elementFromPoint(x, y);
      if (!hit || (hit !== e && !e.contains(hit)))
        stale('Another element covers this target; observe again before clicking.');
      dispatched = true;
      e.click();
      return {ok: true, message: 'Dispatched a page click; verify the next observation.'};
    }
    if (action === 'browser_type') {
      if (e.readOnly || !['INPUT', 'TEXTAREA'].includes(e.tagName))
        throw new Error('Only editable text inputs and textareas are supported.');
      if (e.tagName === 'INPUT' && !['text', 'search', 'email', 'url', 'tel', 'number'].includes(e.type))
        throw new Error('Unsupported input type.');
      const proto = e.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      dispatched = true;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(e, a.text);
      e.dispatchEvent(new Event('input', {bubbles: true}));
      e.dispatchEvent(new Event('change', {bubbles: true}));
      if (e.value !== a.text)
        throw new Error('The page did not retain the entered text; input may have partially applied.');
      return {ok: true, message: 'Set the text field without submitting; verify the next observation.'};
    }
    throw new Error('Unsupported page action.');
  } catch (e) {
    return {ok: false, kind: !dispatched && e.kind === 'stale' ? 'stale' : 'action',
      dispatched, error: String(e.message || e)};
  }
})(__LITECU_PARAMETERS__))
