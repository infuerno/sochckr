I clicked on the "edit" button expecting it to tell me I'd need a certain amount of reputation to edit, but I was presented with an editable post. I corrected the broken links, and submitted to be approved. 

If I wrote a broken link checker to find issues and then manually checked the correct URL, which in the couple of cases I'd found so far hadn't taken long then I could boost my reputation a bit.

There were several different approaches to implementation:
1. Script which runs locally and stores info locally - easy to set up, but would mean would only run when computer was running
2. Application which runs in a browser and stores to local storage - would be reachable from anywhere, but would store results locally for that particular user - again would only run when that browser window was open and working
3. Server application which runs on a cloud server, storing information on a cloud server somewhere - could run 24/7

I decided to write it in Ruby since I'd used Ruby for this kind of thing before. I would need a way of keeping track of posts which had been checked, and also broken links found. Redis is easy to setup and use with Ruby.

Is there an API?

## Problem 1 - how to decide which slice of posts to retrieve at a time

Question IDs appeared to be allocated sequentially so...

### Attempt 1 - Get a random question based on all questions ever published
1. Get most recent question number
2. Choose a random number between 1 and the most recent number
3. Get details of question, check for broken links, record result
4. Rinse and repeat

#### Issues
1. Understanding the way posts, questions and answers are related and assigned IDs. IDs are allocated sequentially to posts not questions. But this is fine, just grab a random question OR answer. However...
2. Questions get deleted, so there may not be an entry for the number chosen

### Attempt 2 - Get a random selection of questions based on a random start date
1. Get the oldest post and the creation date of said post

* Use HEAD not GET
* Need to follow redirect URLs in the case of a `Location` response header
* Some servers don't accept HEAD and return various HTTP response codes in this instance e.g. 405, 404
* Some broken links are where people have uploaded images, code snippets, projects, fiddles to external services to demonstate their problem, but this content no longer exists