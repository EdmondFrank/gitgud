import "phoenix_html"

import hooks from "./hooks"

import * as bulmaToast from 'bulma-toast'

import "../css/app.scss"

window.toast = bulmaToast.toast;

document.addEventListener("DOMContentLoaded", () => {
  hooks.forEach(hook => hook())
})
