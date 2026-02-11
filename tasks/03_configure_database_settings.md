# Task: Configure Admin Settings

## Archetype
Setup / Configuration

## Prompt
Open the Admin panel by clicking the gear icon in the top-right corner and
selecting "Admin settings". Complete the following configuration changes:

1. Navigate to the "Databases" section. Verify the Sample Database connection
   is healthy — it should show a green status indicator or "Synced" label.
2. Navigate to "Settings" > "General". Change the "Site Name" from its
   current value to "Analytics Hub". Save the change.
3. Navigate to "Settings" > "Homepage". Change the homepage setting so that
   it shows a custom collection or pinned items instead of the default
   Metabase greeting. Save the change.

Return to the main application (exit Admin) and confirm the site name in
the top-left now reads "Analytics Hub".

## Expected Result
- Admin > Databases shows the Sample Database with a healthy/synced status
- The site name in the top-left of the application reads "Analytics Hub"
- The homepage setting has been changed from the default
- All changes are saved and persist after a page reload

## Seed Data Required
- Metabase is set up with admin user (admin@example.com / Admin123!)
- Sample Database is connected and synced
