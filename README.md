GitHub Spring Cleaning
---

This app flows through your repos that you own and helps you audit then and clean them up.

You will be able to archive repos, delete repos, and close all issues on repos ... granted you have access, of course!

### To Run

1. Clone the repo with `git clone https://github.com/jules2689/spring_cleaning.git`
2. Choose any non-system Ruby (I use 2.6.x)
3. Run `ruby clean.rb`
   - This will download the needed dependencies using Bundler Inline, direct you on getting a GitHub Token, and then walk you through the process
   - After downloading the list of repos, you can quit at any time using `CTRL-C`. Your progress will be saved.

### Repo Cache

- Stored in `data/repos.json`
- Prevents the app from downloading your repos every time, which are long and expensive calls if you have a lot
- Delete the file to prevent issues

### Decision Cache

- Stored in `data/decisions.json`
- Keeps a decision of all your actions
- Will tell the app to skip processing a repo if you deleted, archived, or skipped a repo before
- Delete the file to reset the decision process
