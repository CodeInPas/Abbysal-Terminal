# Abyssal Terminal: Mariana OS 🌊🖥️

> *"In the abyss, light is a luxury and sound is a death sentence. Type fast, or drown in the dark."*

**Abyssal Terminal: Mariana OS** is a real-time, command-line interface (CLI) survival horror simulation game. You play as a remote operator tasked with guiding a fragile, multi-million dollar bathyscaphe down to the absolute bottom of the Mariana Trench (10,900 meters) to extract rare minerals. 

<img width="1000" height="522" alt="image" src="https://github.com/user-attachments/assets/a55e23cb-4cf9-4b1b-b7ba-d4362b69c579" />


There are no windows. No joysticks. Your only connection to the vessel is a simulated CRT terminal, a raw telemetry feed, and a degrading umbilical text link. 

## ✨ Key Features

*   **Typing for Survival:** Control every aspect of the submarine (thrusters, power routing, sonar, pressure valves) entirely through CLI commands in real-time.
*   **Hydrostatic Physics:** Monitor the PSI differential. Descend too fast without purging your pressure valves, and your hull will implode.
*   **Signal Latency:** As you dive deeper, umbilical cord degradation causes command delays (latency up to 2.2 seconds). You must anticipate your moves before you crash.
*   **Acoustic Evasion (Survival Horror):** The trench is not empty. Giant biological anomalies (Leviathans) hunt by sound. Use active sonar to find minerals, but switch to passive hydrophones and cut your engines to hide when they approach.
*   **System Degradation & EMPs:** Taking damage or getting too close to entities causes electromagnetic interference, resulting in CRT screen tearing and CLI syntax corruption (e.g., your `thruster` command turns into `tHrU$t@r`).
*   **Lore & Blackbox Recovery:** Discover and extract encrypted flight recorders from previous failed expeditions to piece together the dark narrative of the Mariana Trench.

## 🛠️ Tech Stack & Requirements

This project is built natively using **Free Pascal** and the **Lazarus IDE**. 
It utilizes custom off-screen rendering via `BGRABitmap` for high-performance CRT effects.

*   **Language:** Free Pascal (FPC)
*   **IDE:** Lazarus 
*   **Graphics:** BGRABitmap (for the simulated phosphor CRT UI and radar rendering)
*   **Architecture:** Custom 60Hz loop engine (`uGameEngine.pas`) with SQLite database telemetry logging.

## 🚀 Installation & Build Instructions

1. Ensure you have [Lazarus IDE](https://www.lazarus-ide.org/) installed.
2. Install the **BGRABitmap** package via the Lazarus Online Package Manager (OPM).
3. Clone this repository:
