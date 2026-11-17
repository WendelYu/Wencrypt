//! Small P0 causal model; not the production entry/schema engine.
use std::collections::{BTreeMap, BTreeSet};
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Revision {
    pub id: String,
    pub entry: String,
    pub parents: Vec<String>,
    pub deleted: bool,
}
#[derive(Debug, Default, PartialEq, Eq)]
pub struct View {
    pub heads: BTreeSet<String>,
    pub pending: BTreeSet<String>,
}
pub fn evaluate(input: &[Revision]) -> Result<View, &'static str> {
    let mut all = BTreeMap::new();
    for r in input {
        if let Some(old) = all.insert(r.id.clone(), r) {
            if old != r {
                return Err("revision collision");
            }
        }
        if r.parents.iter().collect::<BTreeSet<_>>().len() != r.parents.len() {
            return Err("duplicate parent");
        }
    }
    fn visit(
        id: &str,
        all: &BTreeMap<String, &Revision>,
        visiting: &mut BTreeSet<String>,
        valid: &mut BTreeSet<String>,
        pending: &mut BTreeSet<String>,
    ) -> Result<bool, &'static str> {
        if valid.contains(id) {
            return Ok(true);
        }
        if pending.contains(id) {
            return Ok(false);
        }
        let Some(r) = all.get(id) else {
            return Ok(false);
        };
        if !visiting.insert(id.to_string()) {
            return Err("cycle");
        }
        let mut complete = true;
        for p in &r.parents {
            if let Some(parent) = all.get(p) {
                if parent.entry != r.entry {
                    return Err("cross-entry parent");
                }
            }
            complete &= visit(p, all, visiting, valid, pending)?;
        }
        visiting.remove(id);
        if complete {
            valid.insert(id.to_string());
        } else {
            pending.insert(id.to_string());
        }
        Ok(complete)
    }
    // Prototype resource bound also limits recursive traversal depth.
    if all.len() > 128 {
        return Err("P0 model limit");
    }
    let mut valid = BTreeSet::new();
    let mut pending = BTreeSet::new();
    for id in all.keys() {
        visit(id, &all, &mut BTreeSet::new(), &mut valid, &mut pending)?;
    }
    let mut heads = valid.clone();
    for id in &valid {
        for p in &all[id].parents {
            heads.remove(p);
        }
    }
    Ok(View { heads, pending })
}
#[cfg(test)]
mod tests {
    use super::*;
    fn r(id: &str, parents: &[&str], deleted: bool) -> Revision {
        Revision {
            id: id.into(),
            entry: "entry".into(),
            parents: parents.iter().map(|s| s.to_string()).collect(),
            deleted,
        }
    }
    #[test]
    fn concurrent_delete_edit_and_resolution() {
        let base = r("a", &[], false);
        let edit = r("b", &["a"], false);
        let delete = r("c", &["a"], true);
        let v = evaluate(&[base.clone(), edit.clone(), delete.clone()]).unwrap();
        assert_eq!(v.heads, BTreeSet::from(["b".into(), "c".into()]));
        let resolved = r("d", &["b", "c"], false);
        assert_eq!(
            evaluate(&[base, edit, delete, resolved]).unwrap().heads,
            BTreeSet::from(["d".into()])
        );
    }
    #[test]
    fn permutations_duplicates_and_missing_parent() {
        let a = r("a", &[], false);
        let b = r("b", &["a"], false);
        let c = r("c", &["a"], true);
        let expected = evaluate(&[a.clone(), b.clone(), c.clone()]).unwrap();
        for input in [
            [&a, &b, &c],
            [&a, &c, &b],
            [&b, &a, &c],
            [&b, &c, &a],
            [&c, &a, &b],
            [&c, &b, &a],
        ] {
            assert_eq!(
                evaluate(&input.into_iter().cloned().collect::<Vec<_>>()).unwrap(),
                expected
            );
        }
        assert_eq!(
            evaluate(&[a.clone(), b.clone(), c.clone(), b.clone()]).unwrap(),
            expected
        );
        assert_eq!(
            evaluate(std::slice::from_ref(&b)).unwrap().pending,
            BTreeSet::from(["b".into()])
        );
        assert_eq!(
            evaluate(&[a, c]).unwrap().heads,
            BTreeSet::from(["c".into()])
        );
    }
    #[test]
    fn reject_cycles_cross_entry_and_collisions() {
        assert!(evaluate(&[r("a", &["b"], false), r("b", &["a"], false)]).is_err());
        assert!(evaluate(&[r("a", &[], false), r("a", &[], true)]).is_err());
        let mut b = r("b", &["a"], false);
        b.entry = "other".into();
        assert!(evaluate(&[r("a", &[], false), b]).is_err());
    }
}
