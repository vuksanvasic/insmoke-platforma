// Podešavanja Supabase projekta (insmoke-platforma).
// "anon public" ključ je javan po dizajnu — podatke štiti zaštita u bazi (RLS), ne ovaj ključ.
// NIKADA ovde ne stavljati "service_role" ključ.
window.APP_CONFIG = {
  SUPABASE_URL: "https://ogtegrqmhnwdesaruwvw.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9ndGVncnFtaG53ZGVzYXJ1d3Z3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI2OTIxNjksImV4cCI6MjEwODI2ODE2OX0.VTpdj0hlbvJvuMIUVezBPfPFWj99F9nGS5dIDNIW1ZI"
};
