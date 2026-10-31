import { Controller } from "../vendor/stimulus.js";
export default class extends Controller {
  static targets = ["output"];
  greet() { this.outputTarget.textContent = "Hello from Stimulus"; }
}
