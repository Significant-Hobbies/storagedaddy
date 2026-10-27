/** Render the public template's text fields in reading order, excluding chrome. */
export function templateMarkdown(content) {
  const lines = [];
  function text(value, prefix = '') {
    if (typeof value !== 'string' || !value.trim()) return;
    lines.push(`${prefix}${value}`, '');
  }
  function visit(node, depth = 2) {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) {
      node.forEach((item) => visit(item, depth));
      return;
    }
    const item = node;
    visit(item.header, depth);
    text(item.title, `${'#'.repeat(Math.min(depth, 3))} `);
    text(item.eyebrow);
    text(item.kicker);
    text(item.q, '### ');
    text(item.a);
    text(item.lede);
    text(item.body);
    text(item.text);
    text(item.status);
    if (typeof item.label === 'string')
      text(typeof item.href === 'string' ? `[${item.label}](${item.href})` : item.label);
    text(item.alt);
    for (const key of ['primary', 'secondary', 'status', 'screen', 'window', 'detail'])
      visit(item[key], depth + 1);
    if (typeof item.caption === 'string') text(item.caption);
    else if (item.caption && typeof item.caption === 'object') {
      text(item.caption.lead);
      text(item.caption.text);
    }
    for (const key of ['sections', 'blocks', 'items', 'rows', 'points', 'aside', 'features'])
      visit(item[key], depth + 1);
    text(item.note);
    text(item.credit);
  }
  if (content && typeof content === 'object') {
    const page = content;
    visit(page.hero, 2);
    visit(page.sections);
    visit(page.closing);
  }
  return lines.join('\n');
}
