# Bleeding Edge AI (Intelligence Terminal)

![Flutter](https://img.shields.io/badge/Flutter-%2302569B.svg?style=for-the-badge&logo=Flutter&logoColor=white)
![Dart](https://img.shields.io/badge/dart-%230175C2.svg?style=for-the-badge&logo=dart&logoColor=white)
![Gemini API](https://img.shields.io/badge/Google%20Gemini-8E75B2?style=for-the-badge&logo=google%20gemini&logoColor=white)
![GitHub API](https://img.shields.io/badge/GitHub%20API-181717?style=for-the-badge&logo=github&logoColor=white)

An autonomous, cross-platform intelligence terminal built to aggregate, simplify, and predict bleeding-edge artificial intelligence trends before they hit the mainstream. 

Instead of passively reading tech news, this app actively hunts down zero-day GitHub repositories and raw arXiv research papers, utilizing **Google's Gemini 2.5 Flash API** to translate PhD-level jargon into plain English and automatically organize your personal knowledge vault.

---

## God-Tier Features

*  **The Horizon Scanner:** An AI agent that actively predicts 3 hyper-niche, future AI subfields (e.g., Quantum ML, Liquid Neural Networks) and dynamically rewires API requests to hunt down unknown tech.
*  **The AI Interrogator:** A built-in chatbot attached to every article. Don't just read the abstract—interrogate it. Includes 1-click **"Explain Like I'm 5"** prompt engineering.
*  **Smart Folders (Auto-Categorization):** When you save a paper, Gemini reads the abstract in the background and automatically generates a dynamic category tag to organize your Vault.
*  **Discipline Tracker (Gamification):** A local dashboard that tracks your consecutive daily reading streak and total intel gathered to build unbreakable learning habits.
*  **Tinder-Style UX:** Fluid, gesture-based interface. Swipe Right to save to your local "Second Brain", Swipe Left to discard.
*  **Dual-API Ingestion:** Merges live data streams from the **arXiv API** (academic papers) and **GitHub REST API** (trending open-source code).
*  **Native Social Sharing:** 1-tap export to share your findings to LinkedIn or X directly from the app.

---

##  Architecture & Tech Stack

* **Frontend Framework:** Flutter / Dart
* **AI Engine:** `google_generative_ai` (Gemini 2.5 Flash)
* **Data Pipelines:** `http`, `xml` (arXiv parsing), JSON decoding (GitHub)
* **Local Storage:** `shared_preferences` (Persistent Vault & Streak tracking)
* **UI/UX:** `flutter_card_swiper`
* **Device Integration:** `url_launcher` (Browser routing), `share_plus` (Native sharing)

---

##  Getting Started

To run this intelligence terminal locally on your machine, follow these steps:

### 1. Prerequisites
* Flutter SDK installed (v3.0.0+)
* A free API key from [Google AI Studio](https://aistudio.google.com/)

### 2. Installation
Clone the repository and install the dependencies:
```bash
git clone [https://github.com/YOUR_USERNAME/bleeding-edge-ai.git](https://github.com/YOUR_USERNAME/bleeding-edge-ai.git)
cd bleeding-edge-ai
flutter pub get
