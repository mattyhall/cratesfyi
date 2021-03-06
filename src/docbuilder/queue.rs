//! Updates crates.io index and builds new packages


use super::DocBuilder;
use DocBuilderError;
use rustc_serialize::json::Json;
use git2;
use db::connect_db;


impl DocBuilder {
    /// Updates crates.io-index repository and adds new crates into build queue
    pub fn get_new_crates(&self) -> Result<(), DocBuilderError> {

        let repo = try!(git2::Repository::open(&self.options.crates_io_index_path));

        let old_tree = try!(self.head_tree(&repo));
        try!(self.update_repo(&repo));
        let new_tree = try!(self.head_tree(&repo));

        let diff = try!(repo.diff_tree_to_tree(Some(&old_tree), Some(&new_tree), None));
        let conn = try!(connect_db());

        try!(diff.print(git2::DiffFormat::Patch, |_, _, diffline| -> bool {
            let line = String::from_utf8_lossy(diffline.content()).into_owned();
            // crate strings starts with '{'
            // skip if line is not a crate string
            if line.chars().nth(0) != Some('{') {
                return true;
            }
            let json = match Json::from_str(&line[..]) {
                Ok(j) => j,
                Err(err) => {
                    error!("Failed to parse crate string: {}", err);
                    // just continue even if we get an error for a crate
                    return true;
                }
            };

            if let Some((krate, version)) = json.as_object()
                                                .map(|obj| {
                                                    (obj.get("name")
                                                        .and_then(|n| n.as_string()),
                                                     obj.get("vers")
                                                        .and_then(|n| n.as_string()))
                                                }) {

                // Skip again if we can't get crate name and version
                if krate.is_none() || version.is_none() {
                    return true;
                }

                let _ = conn.execute("INSERT INTO queue (name, version) VALUES ($1, $2)",
                                     &[&krate.unwrap(), &version.unwrap()]);
            }

            true
        }));

        Ok(())
    }


    fn update_repo(&self, repo: &git2::Repository) -> Result<(), git2::Error> {
        let mut remote = try!(repo.find_remote("origin"));
        try!(remote.fetch(&["refs/heads/*:refs/remotes/origin/*"], None, None));

        // checkout master
        try!(repo.refname_to_id("refs/remotes/origin/master")
                 .and_then(|oid| repo.find_object(oid, None))
                 .and_then(|object| repo.reset(&object, git2::ResetType::Hard, None)));

        Ok(())
    }


    fn head_tree<'a>(&'a self, repo: &'a git2::Repository) -> Result<git2::Tree, git2::Error> {
        repo.head()
            .ok()
            .and_then(|head| head.target())
            .ok_or(git2::Error::from_str("HEAD SHA1 not found"))
            .and_then(|oid| repo.find_commit(oid))
            .and_then(|commit| commit.tree())
    }


    /// Builds packages from queue
    pub fn build_packages_queue(&mut self) -> Result<(), DocBuilderError> {
        let conn = try!(connect_db());

        for row in &try!(conn.query("SELECT id, name, version FROM queue ORDER BY id ASC", &[])) {
            let id: i32 = row.get(0);
            let name: String = row.get(1);
            let version: String = row.get(2);

            if let Ok(_) = self.build_package(&name[..], &version[..]) {
                // remove package from que
                let _ = conn.execute("DELETE FROM queue WHERE id = $1", &[&id]);
            } else {
                warn!("Failed to build package {}-{} from queue", name, version);
            }
        }

        Ok(())
    }
}





#[cfg(test)]
mod test {
    extern crate env_logger;
    use std::path::PathBuf;
    use {DocBuilder, DocBuilderOptions};

    #[test]
    #[ignore]
    fn test_get_new_crates() {
        let _ = env_logger::init();
        let options = DocBuilderOptions::from_prefix(PathBuf::from("../cratesfyi-prefix"));
        let docbuilder = DocBuilder::new(options);
        assert!(docbuilder.get_new_crates().is_ok());
    }


    #[test]
    #[ignore]
    fn test_build_packages_queue() {
        let _ = env_logger::init();
        let options = DocBuilderOptions::from_prefix(PathBuf::from("../cratesfyi-prefix"));
        let mut docbuilder = DocBuilder::new(options);
        assert!(docbuilder.build_packages_queue().is_ok());
    }
}
