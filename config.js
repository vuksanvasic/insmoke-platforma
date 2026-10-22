// Podešavanja Supabase projekta.
// Vrednosti se nalaze u Supabase → Project Settings → API.
// "anon public" ključ je javan po dizajnu — podatke štiti zaštita u bazi (RLS), ne ovaj ključ.
// NIKADA ovde ne stavljati "service_role" ključ.
window.APP_CONFIG = {
  SUPABASE_URL: "https://VAS-PROJEKAT.supabase.co",
  SUPABASE_ANON_KEY: "OVDE-IDE-ANON-PUBLIC-KLJUC"
};
