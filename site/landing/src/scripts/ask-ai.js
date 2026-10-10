// The Worker's form-action 'none' disallows the library's GET forms. Open the
// chosen assistant as an ordinary user-triggered navigation, without a fetch.
document.addEventListener('click', (event) => {
  const button = event.target.closest?.('[data-assistant-url]');
  if (!button) return;
  const question = button.closest('form')?.querySelector('[name="q"]')?.value;
  if (!question?.trim()) return;
  event.preventDefault();
  const url = new URL(button.dataset.assistantUrl);
  url.searchParams.set('q', question);
  window.open(url.href, '_blank', 'noopener,noreferrer');
});
