const LM = 'light-mode', DM = 'dark-mode';
const setTheme = (preference) => {
  let classList = document.body.classList;
  classList.remove(LM, DM);
  if (preference == LM) {
    classList.add(LM);
  } else if (preference == DM) {
    classList.add(DM);
  }
};

const newPreference = (oldpref) => {
  if (oldpref == DM) {
    return LM;
  } else if (oldpref == LM) {
    return DM;
  }
  let mm = window.matchMedia;
  return mm && mm('(prefers-color-scheme: dark)').matches ? LM : DM;
};

const subtitles = [
  '# container manager',
  'build :all',
  'run dev',
  'run website',
  'update prod',
  'update --remote=prod',
  'run --remote=server',
  'diff prod',
  'shell $container',
  'logs $container',
  'attach $container',
  'init',
  'script main.rb',
  'repl python',
];

const animateTitle = (lastIdx) => {
  let index = Math.floor(Math.random()*subtitles.length);
  if (index == lastIdx) {
    index = (index + 1) % subtitles.length;
  }
  let item = subtitles[index];
  let elem = document.getElementById('live-subtitle');
  elem.innerHTML = '';
  for (let i = 0; i < item.length; i++) {
    window.setTimeout(() => {
      elem.innerText += item[i];
    }, (Math.random() * 50) + 180 * (i + 5));
  }

  window.setTimeout(() => {
    animateTitle(index);
  }, (230 * (item.length + 5)) + 2000);
};

addEventListener('load', () => {
  const PT = 'theme-toggle';
  let toggle = document.getElementById(PT);
  let reset = document.getElementById('theme-reset');
  let preference = localStorage.getItem(PT);
  if (!preference) {
    reset.style.display = 'none';
  }
  toggle.onclick = () => {
    preference = newPreference(localStorage.getItem(PT));
    setTheme(preference);
    localStorage.setItem(PT, preference);
    reset.style.display = 'inline';
  };

  Array.from(document.querySelectorAll('.post-body a.footnote')).forEach(foot => {
    let ref = document.getElementById(foot.getAttribute('href').substr(1));
    if (ref) {
      foot.setAttribute('title', ref.innerText.trim());
    }
  });

  window.setTimeout(() => {
    animateTitle();
  }, 2000);
});
