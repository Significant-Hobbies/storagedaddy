//! Read-only bridge from StorageDaddy scan metadata to FinderSearch's fsearch index.
use fsearch::{
    Query,
    index::Index,
    live::Live,
    query::Searcher,
    walk::{KIND_DIR, Listing, NONE, RawEnt},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::{self, BufRead, Write},
    path::Path,
    time::Instant,
};

#[derive(Deserialize)]
struct Node {
    id: u32,
    parent: Option<u32>,
    name: String,
    kind: u8,
    size: u64,
    mtime: u32,
}
#[derive(Deserialize)]
struct Request {
    op: String,
    #[serde(default)]
    root: String,
    #[serde(default)]
    nodes: Vec<Node>,
    #[serde(default)]
    q: String,
    #[serde(default)]
    scope: u32,
}
struct Snapshot {
    live: Live,
    node_entries: HashMap<u32, u32>,
    entry_nodes: Vec<Option<u32>>,
}

fn entry(
    listing: &mut Listing,
    name: &str,
    kind: u8,
    size: u64,
    mtime: u32,
    child: u32,
) -> Result<(), String> {
    let len = u16::try_from(name.len()).map_err(|_| "Filename too long")?;
    let offset = u32::try_from(listing.names.len()).map_err(|_| "Scan too large")?;
    listing.names.extend_from_slice(name.as_bytes());
    listing.ents.push(RawEnt {
        name_off: offset,
        name_len: len,
        kind,
        size,
        mtime,
        child,
    });
    Ok(())
}
fn listing(id: u32) -> Listing {
    Listing {
        id,
        names: vec![],
        ents: vec![],
    }
}

impl Snapshot {
    fn load(root: &str, nodes: Vec<Node>) -> Result<Self, String> {
        if !Path::new(root).is_absolute()
            || nodes
                .first()
                .is_none_or(|n| n.id != 0 || n.parent.is_some() || n.kind != KIND_DIR)
        {
            return Err("Invalid scan root".into());
        }
        let components: Vec<_> = Path::new(root)
            .components()
            .filter_map(|c| {
                if let std::path::Component::Normal(s) = c {
                    s.to_str()
                } else {
                    None
                }
            })
            .collect();
        let depth = components.len() as u32;
        let mut listings: HashMap<u32, Listing> = HashMap::new();
        for (i, component) in components.iter().enumerate() {
            let mut l = listing(i as u32);
            entry(&mut l, component, KIND_DIR, 0, 0, i as u32 + 1)?;
            listings.insert(l.id, l);
        }
        let mut names = HashMap::new();
        for (i, n) in nodes.iter().enumerate() {
            if n.id as usize != i
                || (i > 0 && n.parent.is_none_or(|p| p as usize >= i))
                || (i > 0 && (n.name.is_empty() || n.name.contains('/') || n.name.contains('\0')))
            {
                return Err("Invalid scan tree".into());
            }
            if n.kind == KIND_DIR {
                listings.insert(depth + n.id, listing(depth + n.id));
            }
            if let Some(parent) = n.parent {
                names.insert((parent, n.name.clone()), n.id);
            }
        }
        for n in &nodes {
            if let Some(parent) = n.parent {
                let l = listings
                    .get_mut(&(depth + parent))
                    .ok_or("Parent is not a directory")?;
                entry(
                    l,
                    &n.name,
                    n.kind,
                    n.size,
                    n.mtime,
                    if n.kind == KIND_DIR {
                        depth + n.id
                    } else {
                        NONE
                    },
                )?;
            }
        }
        let home = std::env::var("HOME").unwrap_or_default();
        let index = Index::build(listings.into_values().collect(), 0, 0, home.as_bytes());
        let root_entry = index
            .lookup(root.trim_end_matches('/').as_bytes())
            .or_else(|| (root == "/").then_some(0))
            .ok_or("Root not indexed")?;
        let mut entry_nodes = vec![None; index.n];
        let mut node_entries = HashMap::new();
        entry_nodes[root_entry as usize] = Some(0);
        node_entries.insert(0, root_entry);
        for e in 1..index.n {
            if e == root_entry as usize {
                continue;
            }
            let parent_entry = index.dir_entry()[index.parent()[e] as usize] as usize;
            if let Some(parent_node) = entry_nodes[parent_entry] {
                let name = String::from_utf8_lossy(index.name(e)).into_owned();
                if let Some(&id) = names.get(&(parent_node, name)) {
                    entry_nodes[e] = Some(id);
                    node_entries.insert(id, e as u32);
                }
            }
        }
        Ok(Self {
            live: Live::new(index),
            node_entries,
            entry_nodes,
        })
    }
    fn search(&self, text: &str, scope: u32) -> Result<Value, String> {
        let home = std::env::var("HOME").unwrap_or_default();
        let mut q = Query::parse(text, &home)?;
        if q.grep.is_some() {
            return Err("Use filename filters; content search is not supported".into());
        }
        let e = *self
            .node_entries
            .get(&scope)
            .ok_or("Folder not in this scan")?;
        if self.live.base.dir_of(e).is_none() {
            return Err("Search scope must be a folder".into());
        }
        let mut folder = vec![];
        self.live.base.path(e as usize, &mut folder);
        if let Some(requested) = &q.scope {
            if folder != b"/"
                && requested != &folder
                && !(requested.starts_with(&folder) && requested.get(folder.len()) == Some(&b'/'))
            {
                return Ok(json!({"ok":true,"hits":[],"took_us":0}));
            }
        } else {
            q.scope = Some(folder);
        }
        // UI cap is explicit; query limit: cannot make the helper return unbounded results.
        q.limit = 201;
        let started = Instant::now();
        let hits: Vec<_> = Searcher { live: &self.live }
            .search(&q)
            .into_iter()
            .filter_map(|h| {
                self.entry_nodes[h.idx as usize].map(|id| json!({"id":id,"score":h.score}))
            })
            .collect();
        Ok(json!({"ok":true,"hits":hits,"took_us":started.elapsed().as_micros() as u64}))
    }
}
fn main() {
    let mut snapshot: Option<Snapshot> = None;
    let mut output = io::BufWriter::new(io::stdout().lock());
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let result = serde_json::from_str::<Request>(&line)
            .map_err(|e| e.to_string())
            .and_then(|r| match r.op.as_str() {
                "load" => {
                    snapshot = None;
                    snapshot = Some(Snapshot::load(&r.root, r.nodes)?);
                    Ok(json!({"ok":true}))
                }
                "search" => snapshot
                    .as_ref()
                    .ok_or("Load a scan first".into())
                    .and_then(|s| s.search(&r.q, r.scope)),
                _ => Err("Unknown operation".into()),
            });
        let reply = result.unwrap_or_else(|error| json!({"ok":false,"error":error}));
        if writeln!(output, "{reply}")
            .and_then(|_| output.flush())
            .is_err()
        {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use fsearch::walk::{KIND_FILE, KIND_LINK};
    fn node(id: u32, parent: Option<u32>, name: &str, kind: u8) -> Node {
        Node {
            id,
            parent,
            name: name.into(),
            kind,
            size: 4_000_000,
            mtime: fsearch::query::now_secs(),
        }
    }
    fn snapshot(root: &str) -> Snapshot {
        Snapshot::load(
            root,
            vec![
                node(0, None, "Fixture", KIND_DIR),
                node(1, Some(0), "Projects", KIND_DIR),
                node(2, Some(1), "report.pdf", KIND_FILE),
                node(3, Some(0), "report.txt", KIND_FILE),
                node(4, Some(1), "report-link.pdf", KIND_LINK),
            ],
        )
        .unwrap()
    }
    #[test]
    fn fuzzy_filters_and_recursive_scope() {
        let s = snapshot("/tmp/search fixture");
        let r = s
            .search("reprot ext:pdf size:>1mb mtime:<7d kind:file", 0)
            .unwrap();
        assert_eq!(r["hits"][0]["id"], 2);
        assert_eq!(r["hits"].as_array().unwrap().len(), 1);
        assert_eq!(
            s.search("report", 1).unwrap()["hits"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert_eq!(
            s.search("report in:/elsewhere", 1).unwrap()["hits"],
            json!([])
        );
        assert!(s.search("grep:secret", 0).is_err());
        assert!(s.search("kind:invalid", 0).is_err());
    }
    #[test]
    fn root_scope_and_empty_folder() {
        assert_eq!(
            snapshot("/").search("ext:txt", 0).unwrap()["hits"][0]["id"],
            3
        );
        let s = Snapshot::load("/tmp/empty", vec![node(0, None, "empty", KIND_DIR)]).unwrap();
        assert_eq!(s.search("report", 0).unwrap()["hits"], json!([]));
    }
}
