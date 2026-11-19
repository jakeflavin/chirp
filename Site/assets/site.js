// Plays each scene only while it is on screen, and lands the bird on each section's wire.
// Without this file the page still works: every scene simply plays.
(() => {
  const page = document.getElementById('page');
  if (!page || !('IntersectionObserver' in window)) return;
  page.classList.add('js');
  const seen = new IntersectionObserver(entries => {
    for (const e of entries) e.target.classList.toggle('in', e.isIntersecting);
  }, { rootMargin: '0px 0px -25% 0px', threshold: 0.05 });
  for (const s of page.querySelectorAll('.watch')) seen.observe(s);
})();
