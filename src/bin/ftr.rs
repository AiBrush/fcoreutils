use std::process;

use clap::Parser;

use coreutils_rs::tr;

#[derive(Parser)]
#[command(
    name = "ftr",
    about = "Translate, squeeze, and/or delete characters",
    override_usage = "ftr [OPTION]... SET1 [SET2]"
)]
struct Cli {
    /// Use the complement of SET1
    #[arg(short = 'c', short_alias = 'C', long = "complement")]
    complement: bool,

    /// Delete characters in SET1, do not translate
    #[arg(short = 'd', long = "delete")]
    delete: bool,

    /// Replace each sequence of a repeated character that is listed
    /// in the last specified SET, with a single occurrence of that character
    #[arg(short = 's', long = "squeeze-repeats")]
    squeeze: bool,

    /// First truncate SET1 to length of SET2
    #[arg(short = 't', long = "truncate-set1")]
    truncate: bool,

    /// Character sets
    #[arg(required = true)]
    sets: Vec<String>,
}

fn main() {
    let cli = Cli::parse();

    let set1_str = &cli.sets[0];

    let mut stdin = std::io::stdin().lock();
    let mut stdout = std::io::stdout().lock();

    let result = if cli.delete && cli.squeeze {
        // -d -s: delete SET1 chars, then squeeze SET2 chars — need two sets
        if cli.sets.len() < 2 {
            eprintln!("ftr: missing operand after '{}'", set1_str);
            eprintln!("Two strings must be given when both deleting and squeezing repeats.");
            process::exit(1);
        }
        let set2_str = &cli.sets[1];
        let set1 = tr::parse_set(set1_str);
        let set2 = tr::parse_set(set2_str);
        let delete_set = if cli.complement {
            tr::complement(&set1)
        } else {
            set1
        };
        tr::delete_squeeze(&delete_set, &set2, &mut stdin, &mut stdout)
    } else if cli.delete {
        // -d only: delete SET1 chars
        if cli.sets.len() > 1 {
            eprintln!("ftr: extra operand '{}'", cli.sets[1]);
            eprintln!("Only one string may be given when deleting without squeezing.");
            process::exit(1);
        }
        let set1 = tr::parse_set(set1_str);
        let delete_set = if cli.complement {
            tr::complement(&set1)
        } else {
            set1
        };
        tr::delete(&delete_set, &mut stdin, &mut stdout)
    } else if cli.squeeze && cli.sets.len() < 2 {
        // -s only with one set: squeeze SET1 chars
        let set1 = tr::parse_set(set1_str);
        let squeeze_set = if cli.complement {
            tr::complement(&set1)
        } else {
            set1
        };
        tr::squeeze(&squeeze_set, &mut stdin, &mut stdout)
    } else if cli.squeeze {
        // -s with two sets: translate SET1->SET2, then squeeze SET2 chars
        let set2_str = &cli.sets[1];
        let mut set1 = tr::parse_set(set1_str);
        if cli.complement {
            set1 = tr::complement(&set1);
        }
        let set2 = if cli.truncate {
            let raw = tr::parse_set(set2_str);
            set1.truncate(raw.len());
            raw
        } else {
            tr::expand_set2(set2_str, set1.len())
        };
        tr::translate_squeeze(&set1, &set2, &mut stdin, &mut stdout)
    } else {
        // Default: translate SET1 -> SET2
        if cli.sets.len() < 2 {
            eprintln!("ftr: missing operand after '{}'", set1_str);
            eprintln!("Two strings must be given when translating.");
            process::exit(1);
        }
        let set2_str = &cli.sets[1];
        let mut set1 = tr::parse_set(set1_str);
        if cli.complement {
            set1 = tr::complement(&set1);
        }
        let set2 = if cli.truncate {
            let raw = tr::parse_set(set2_str);
            set1.truncate(raw.len());
            raw
        } else {
            tr::expand_set2(set2_str, set1.len())
        };
        tr::translate(&set1, &set2, &mut stdin, &mut stdout)
    };

    if let Err(e) = result {
        if e.kind() != std::io::ErrorKind::BrokenPipe {
            eprintln!("ftr: {}", e);
            process::exit(1);
        }
    }
}
