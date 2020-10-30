
CREATE TABLE "users" (
  "id" SERIAL PRIMARY KEY,
  --Each username has to be unique,can be composed of at most 25 characters
  "username" VARCHAR(25) NOT NULL,
  --Usernames can’t be empty,composed of at most 25 characters
  "user_login" DATE DEFAULT NULL,
  --will help identify all users who haven’t logged in in the last year

  UNIQUE ("username")
  --Usernames are unique
);

CREATE INDEX "find_user" ON "users"("username");
--Helps to find a user by their username quicker
CREATE INDEX "last_login" ON "users" ("user_login","username");

CREATE TABLE "topics"(
  "id" SERIAL PRIMARY KEY,
  "topic_name" VARCHAR(30) NOT NULL,
  --Topics are unique, can’t be empty, composed of at most 30 characters
  "description" VARCHAR(500) DEFAULT NULL,
  --Topics can have an optional description of at most 500 characters

  UNIQUE ("topic_name")
  --Topics are unique
);

CREATE INDEX "find_topic" ON "topics"("topic_name");
CREATE INDEX "case_unique_topic" ON "topics"(lower("topic_name"));

CREATE TABLE "posts" (
  "id" SERIAL PRIMARY KEY,
  "topic_id" INTEGER,
  "user_id" INTEGER,
  "title" VARCHAR(100) NOT NULL,
  --Posts have a non empty title of at most 100 characters
  "url" VARCHAR(500) DEFAULT NULL,
  -- Reduced VARCHAR from 4000 to 500,
	"text_content" TEXT DEFAULT NULL,
  "time_created" TIMESTAMP WITH TIME ZONE,

  FOREIGN KEY ("topic_id") REFERENCES "topics"("id") ON DELETE CASCADE,
  --topic gets deleted, all the posts associated with it should be automatically deleted too
  FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE SET NULL,
  --If the user gets deleted, post will remain, but it will become dissociated from that user

  CONSTRAINT "text_or_content" CHECK (("url" IS NOT NULL AND "text_content" IS NULL)
                                        OR ("url" IS NULL AND "text_content" IS NOT NULL)),
  --Posts should contain either a URL or a text content, but not both
  CONSTRAINT "title_format" CHECK ("title" NOT LIKE '%[-!#%&+,./:;<=>@`{|}~"()*\\\_\^\\[\]\]%')
);

CREATE INDEX "topic_post" ON "posts"("topic_id", "id");
CREATE INDEX "url_spam_check" ON "posts" ("url" VARCHAR_PATTERN_OPS);
CREATE INDEX "case_unique_title" ON "posts"(lower("title"));
CREATE UNIQUE INDEX "url_per_topic" ON "posts" ("url","title");
CREATE UNIQUE INDEX "title_per_topic" ON "posts" ("topic_id","title");

CREATE TABLE "comments" (
  "id" SERIAL PRIMARY KEY,
  "parent_id" INTEGER DEFAULT NULL,
  "user_id" INTEGER,
	"post_id" INTEGER,
	"text_content" TEXT NOT NULL,
  --A comment’s text content can’t be empty
  "time_created" TIMESTAMP WITH TIME ZONE,

  FOREIGN KEY ("parent_id") REFERENCES "comments"("id") ON DELETE CASCADE,
  --comment threads at arbitrary levels, we will set the original comment with "parent_id" = "id",
  --If a comment gets deleted, then all its descendants be automatically deleted too - literally CASCADE
  FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE SET NULL,
--If a post gets deleted, all comments associated with it should be automatically deleted too
  FOREIGN KEY ("post_id") REFERENCES "posts"("id") ON DELETE CASCADE,
  --If the user gets deleted, the comment will remain, but it will become dissociated from that user
  CONSTRAINT "comment_url_spam" CHECK ("text_content" NOT LIKE '%http://%' AND "text_content" NOT LIKE '%https://%')

);

CREATE INDEX "parent_post_check" ON "comments" ("parent_id","id");
CREATE INDEX "comment_time" ON "comments" ("user_id","time_created");


CREATE TABLE "votes" (
  "post_id" INTEGER,
  "user_id" INTEGER,
  "votes" SMALLINT,

  FOREIGN KEY ("post_id") REFERENCES "posts"("id") ON DELETE CASCADE,
  --If a post gets deleted, then all the votes for that post should be automatically deleted too
  FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE SET NULL,
  --If the user gets deleted, then all their votes will remain, but will become dissociated from the user

  CONSTRAINT "binary_vote" CHECK ("votes" = 1 or "votes" = -1 ),
  CONSTRAINT "one_vote_per_post" UNIQUE ("user_id", "post_id")
   --a given user can only vote once on a given post
);

CREATE INDEX "votes_per_post" ON "votes"("post_id");



--Populating topics with distinct vaules from 'bad_posts'. I will also normalise the topics to all
--lowercase and no special charachters as '_' and will autoassign user_ids
INSERT INTO "topics"("topic_name")
SELECT DISTINCT REPLACE((lower(topic)), '_', ' ')
FROM bad_posts
Order by 1;

--Editing 'topic' formatin 'bad_posts' before migration into the new table
UPDATE "bad_posts" SET "topic" = REPLACE((lower("topic")), '_', ' ');

--Populating unique users from bad_posts into the users table, autocreating user_ids
INSERT INTO "users"("username")
SELECT DISTINCT(username)
FROM bad_posts;

--Populating unique users from bad_comments into the users table avoiding duplicates from users with posts,
--autocreating user_ids
INSERT INTO "users"("username")
SELECT DISTINCT(username)
FROM bad_comments
WHERE bad_comments.username NOT IN (SELECT username from users);

--LATER WE WILL NEED TO ADD USERS FROM VOTES AFTER WE REGEX_SPLIT

--During futher migration we found out that some original post titles are longer than 100 charachters
--we will truncate the existing titles so that we can migrate them into a new table
--any future ones above 100 char will be stopped from being created by VARCHAR(100)
UPDATE bad_posts
SET title = LEFT(title, 100);

--Migrating post title, url and text, combined with newly created user_ids and topic_ids
INSERT INTO "posts"("topic_id", "user_id", "title", "url", "text_content")
SELECT t.id, u.id, b.title, b.url, b.text_content
FROM topics t
JOIN bad_posts b
ON b.topic = t.topic_name
JOIN users u
ON b.username = u.username;

--Migrating UPVOTES into the votes table. We will add a temprorary column username to votes
ALTER TABLE "votes" ADD COLUMN "username" VARCHAR(50);

INSERT INTO "votes" ("username", "post_id")
SELECT regexp_split_to_table(b.upvotes, ','), p.id
from bad_posts b
JOIN posts p
ON p.title = b.title;

--Populating vote value as '1' for all the migrated upvotes:
UPDATE "votes" SET "votes" = 1 where "votes" IS NULL;

--Migrating DOWNVOTES into the votes table
INSERT INTO "votes" ("username", "post_id")
SELECT regexp_split_to_table(b.downvotes, ','), p.id
from bad_posts b
JOIN posts p
ON p.title = b.title;

--Populating vote value as '-1' for all the migrated downvotes:
UPDATE "votes" SET "votes" = -1 where "votes" IS NULL;

--Now we can add the rest of the users to the users table. Users who don't post or comment but only vote
INSERT INTO "users"("username")
SELECT DISTINCT(username)
FROM votes
WHERE votes.username NOT IN (SELECT username from users);

--Populating user_id value for all the migrated votes:
UPDATE "votes" SET "user_id" = (SELECT u.id
                                FROM users u
                                WHERE votes.username = u.username);

--Migrating data into comments:
INSERT INTO "comments" ("post_id", "text_content", "user_id")
SELECT p.id, bc.text_content, u.id
FROM bad_comments bc
JOIN bad_posts bp
ON bp.id = bc.post_id
JOIN users u
ON u.username = bc.username
JOIN posts p
ON p.title = bp.title;

--Cleaning the database:
ALTER TABLE "votes" DROP column "username";

DROP TABLE "bad_comments" CASCADE;
DROP TABLE "bad_posts" CASCADE;
