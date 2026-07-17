const taskCheckboxes = [...document.querySelectorAll("[data-task-checkbox]")];
const progress = document.querySelector("[data-progress]");

function updateProgress() {
  if (!progress) return;
  const completed = taskCheckboxes.filter((checkbox) => checkbox.checked).length;
  progress.textContent = `${completed} / ${taskCheckboxes.length}`;
}

taskCheckboxes.forEach((checkbox) => {
  checkbox.addEventListener("change", updateProgress);
});

document.querySelectorAll("[data-current-year]").forEach((element) => {
  element.textContent = String(new Date().getFullYear());
});

updateProgress();
