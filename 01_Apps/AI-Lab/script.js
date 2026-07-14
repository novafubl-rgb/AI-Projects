const countEl = document.getElementById("count");
const button = document.getElementById("click-btn");

let count = 0;

button.addEventListener("click", () => {
  count += 1;
  countEl.textContent = count;
  countEl.classList.remove("bump");
  // Force reflow so the animation can replay on every click
  void countEl.offsetWidth;
  countEl.classList.add("bump");
});
