// ProjectX shared nav. Each page calls this once at startup. Page declares
// data-page on <body> so the active link gets highlighted. Page declares
// data-version on <body> so the badge stays correct.
//
//   <body data-page="dashboard" data-version="V0.08">
//   <script src="assets/nav.js" defer></script>

(function () {
  const links = [
    { id: 'dashboard', label: 'Dashboard',  href: 'index.html'   },
    { id: 'lines',     label: 'Log',        href: 'lines.html'   },
    { id: 'approve',   label: 'Approve',    href: 'approve.html' },
    { id: 'ap',        label: 'AP',         href: 'ap.html'      },
    { id: 'ar',        label: 'AR',         href: 'ar.html'      },
    { id: 'admin',     label: 'Admin',      href: 'admin.html'   },
  ];

  // Subbie smartform is anonymous public — no internal nav links.
  // It still gets a stripped-down header (brand + project name + version)
  // so the page still feels like ProjectX, just without admin/AP/AR/etc.
  const PUBLIC_PAGES = new Set(['submit']);

  function mount() {
    const body = document.body;
    const page = body.dataset.page || '';
    const version = body.dataset.version || '';
    const project = body.dataset.project || 'Fonterra Maungaturoto 26';
    const isPublic = PUBLIC_PAGES.has(page);

    const header = document.createElement('header');
    header.className = 'projectx-header';
    header.innerHTML = `
      <a class="projectx-brand" ${isPublic ? '' : 'href="index.html"'}>
        Project<span class="mark">X</span>
      </a>
      <span class="projectx-context hide-mobile">${project}</span>
      <span class="projectx-spacer"></span>
      ${isPublic ? '' : `
        <nav class="projectx-nav-links" id="projectx-nav-links">
          ${links.map(l => `
            <a class="projectx-nav-link ${l.id === page ? 'current' : ''}" href="${l.href}">${l.label}</a>
          `).join('')}
        </nav>
        <button class="projectx-mobile-toggle" aria-label="menu" id="projectx-mobile-toggle">
          <svg class="icon-lg" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" fill="none"><path stroke-linecap="round" stroke-linejoin="round" d="M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5"/></svg>
        </button>
      `}
      <span class="projectx-version">${version}</span>
    `;
    body.insertBefore(header, body.firstChild);

    if (!isPublic) {
      const toggle = document.getElementById('projectx-mobile-toggle');
      const linksEl = document.getElementById('projectx-nav-links');
      toggle.addEventListener('click', () => linksEl.classList.toggle('open'));
      document.addEventListener('click', (e) => {
        if (!header.contains(e.target)) linksEl.classList.remove('open');
      });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', mount);
  } else {
    mount();
  }
})();
