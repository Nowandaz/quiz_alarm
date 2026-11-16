/// Where the app's server side lives. All three values are public by
/// design: the key only lets the app talk to the project, and the server's
/// own rules decide what a signed-in person may do. No secret belongs here.
library;

class ServerConfig {
  /// Accounts, question bank and progress (Supabase).
  static const String supabaseUrl = 'https://zsplxgvizlndnofsokxw.supabase.co';
  static const String supabaseKey =
      'sb_publishable_bE2OwJPR9O9mhzRi-HVPLw_lh7G7-LB';

  /// The AI server (writes questions, tutor, marking of typed answers).
  static const String apiUrl =
      'https://jarvis-norys.austriaeast.cloudapp.azure.com/brainwake';
}
