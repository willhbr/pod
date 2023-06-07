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
});
