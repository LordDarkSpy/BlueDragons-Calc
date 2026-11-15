// Configuração do Supabase (Dashboard → Project Settings → API).
// A "anon key" é pública por natureza: a segurança fica nas regras (RLS) do
// arquivo supabase/schema.sql. NUNCA coloque aqui a "service_role key".
window.BD_CONFIG = {
  supabaseUrl: 'https://SEU-PROJETO.supabase.co',
  supabaseAnonKey: 'SUA-ANON-KEY',
};
