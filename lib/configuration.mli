open Commons

type t = {
  config_rna_seq : config_rna_seq ;
  apytram_samples: rna_sample list ;
  trinity_samples : rna_sample list ;
  all_ref_samples : rna_sample list ;
  all_ref_species : string list ;
  all_apytram_ref_species : string list list;
  apytram_group_list : string list ;
  all_families : family list;
  used_families : family list;
  sample_sheet : string ;
  species_tree_file : string ;
  alignments_dir : string ;
  seq2sp_dir : string ;
  outdir : string ;
  threads : int;
  memory : int;
  run_reconciliation : bool;
  refinetree : bool;
  refineali : bool;
  debug : bool;
  get_reads : bool;
  just_parse_input : bool;
  ali_sister_threshold : float;
  merge_criterion : merge_criterion;
}

val load :
  sample_sheet:string ->
  species_tree_file:string ->
  alignments_dir:string ->
  seq2sp_dir:string ->
  np:int ->
  memory:int ->
  run_reconciliation:bool ->
  refinetree:bool ->
  refineali:bool ->
  ali_sister_threshold:float ->
  merge_criterion:string ->
  debug:bool ->
  get_reads:bool ->
  just_parse_input:bool ->
  outdir:string ->
  family_to_use:string option->
  t
