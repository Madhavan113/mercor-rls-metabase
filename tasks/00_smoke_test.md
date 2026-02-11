# Task: Smoke Test — Verify Metabase Is Running

## Archetype
Setup / Configuration

## Prompt
Open the Metabase home page. Confirm the application loads successfully and
you can see the main navigation. Click on "New" in the top navigation bar
to verify the menu appears with options like "Question", "SQL query", and
"Dashboard". Close the menu. Then navigate to the "Our analytics" collection
and confirm that seeded content is visible (saved questions and dashboards
should already exist).

## Expected Result
- The Metabase home page loads without errors
- The top navigation bar is visible with "New", search, and settings icons
- Clicking "New" shows a dropdown with at least "Question", "SQL query",
  and "Dashboard" options
- The "Our analytics" collection is accessible and contains saved items
- The Sample Database is connected (visible under Admin > Databases or
  when creating a new question)

## Seed Data Required
- Metabase is set up with admin user (admin@example.com / Admin123!)
- Sample Database is connected and synced
- Seed script has run (saved questions and dashboard exist)
