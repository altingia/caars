open Core
open Bistro.Std
open Bistro.EDSL
open Bistro_bioinfo.Std
open Bistro_utils
open Commons
open Configuration


let alignement_fasta fam : (output, fasta) selector =
  selector [ "Alignements" ; fam ^ ".fa" ]

let gene_tree fam : (output, [`newick]) selector =
  selector [ "Gene_trees" ; fam ^ ".tree" ]

let sp2seq_link fam : (output, sp2seq_link) selector =
  selector [ "Sp2Seq_link" ; fam ^ ".sp2seq.txt" ]

let parse_input ~sample_sheet ~species_tree_file ~alignments_dir ~seq2sp_dir ~(all_families: family list) ~memory ~configuration : configuration_dir directory workflow =
  let families_out = dest // "DetectedFamilies.txt" in
  let script = Bistro.Template.(
      [[seq ~sep:"\t" [string "Detected_families"; string "Fam_ID"]];
      List.map all_families ~f:(fun fam -> seq ~sep:"\t" [string fam.name; int fam.f_id ])]
      |> List.concat
      |> seq ~sep:"\n"
      )
      in
  let ali_cmd_list = List.map all_families ~f:(fun fam ->
  let ali = input ~may_change:true (configuration.alignments_dir ^ "/" ^ fam.name ^ ".fa") in
  cmd "echo" [dep ali]
  )
  in
  let sp2seq_files = Sys.readdir configuration.seq2sp_dir
  |> Array.filter ~f:(fun f ->
    if Filename.check_suffix f ".tsv" then
      true
    else
      false)
  |> Array.to_list
  in
  let sp2seq_cmd_list = List.map sp2seq_files ~f:(fun sp2seq_file ->
  let sp2seq = input ~may_change:true (configuration.seq2sp_dir ^ "/" ^ sp2seq_file) in
  cmd "echo" [dep sp2seq]
  )
  in
  workflow ~np:1 ~descr:"Parse input" ~version:17 ~mem:(memory * 1024) (List.concat [
    [mkdir_p dest;
    cmd "ParseInput.py"  ~env [ dep sample_sheet ;
                                dep species_tree_file;
                                dep alignments_dir;
                                dep seq2sp_dir;
                                ident dest ;
                              ];
    cmd "cp" [ file_dump script; families_out];
    ];
    ali_cmd_list;
    sp2seq_cmd_list;
  ])

let ref_transcriptomes species : (configuration_dir, fasta) selector =
  selector ["R_Sp_transcriptomes" ;  species ^ "_transcriptome.fa" ]

let ref_seq_fam_links species : (configuration_dir, tabular) selector =
  selector ["R_Sp_Seq_Fam_links";  species ^ "_Fam_Seq.tsv"  ]

let ref_fams species family =
  selector ["R_Sp_Gene_Families"; species ^ "." ^ family ^ ".fa"]

let ali_species2seq_links family =
  selector ["Alignments_Species2Sequences" ; "alignments." ^  family ^ ".sp2seq.txt" ]

let ref_blast_dbs_of_configuration_dir {all_ref_species} configuration_dir =
  List.map all_ref_species ~f:(fun ref_species ->
    let fasta = configuration_dir / ref_transcriptomes ref_species in
    let parse_seqids = true in
    let dbtype = "nucl" in
    (ref_species, BlastPlus.makeblastdb ~parse_seqids ~dbtype  ("DB_" ^ ref_species) fasta)
    )


let fastq_to_fasta_conversion {all_ref_samples} dep_input =
  let dep_input = None in
  List.filter_map all_ref_samples ~f:(fun s ->
      let need_rna = match (s.run_apytram,s.run_trinity, s.given_assembly) with
        |(true,_,_)         -> true
        |(false,true,true)  -> false
        |(false,true,false) -> true
        |(false,false,_)    -> false
      in
      if need_rna then
        let sample_file = sample_file_map input s.sample_file in
        let sample_fastq_to_sample_fasta = function
          | Fastq_Single_end (w, o ) -> Fasta_Single_end ( Trinity.fastq2fasta ~descr:(s.id ^ "_" ^ s.species) ~dep_input w , o )
          | Fastq_Paired_end (lw, rw , o) -> Fasta_Paired_end ( Trinity.fastq2fasta ~descr:(s.id ^ "_" ^ s.species ^ "_left") ~dep_input lw , Trinity.fastq2fasta ~descr:(s.id ^ "_" ^ s.species ^ "_right") ~dep_input rw , o)
        in
        let sample_fasta = match sample_file with
            | Sample_fasta x -> x
            | Sample_fastq x -> sample_fastq_to_sample_fasta x
        in
        Some (s,sample_fasta)
      else
        None
    )

let normalize_fasta fasta_reads memory max_memory threads =
  List.map fasta_reads ~f:(fun (s, fasta_sample) ->
      let max_cov = 20 in
      let normalization_dir = Trinity.fasta_read_normalization_2 ~descr:(s.id ^ "_" ^ s.species) max_cov ~threads ~memory ~max_memory fasta_sample in
      let norm_fasta_sample_to_normalization_dir normalization_dir = function
        | Fasta_Single_end (w, o ) -> Fasta_Single_end ( normalization_dir / selector ["single.norm.fa"] , o )
        | Fasta_Paired_end (lw, rw , o) -> Fasta_Paired_end ( normalization_dir / selector ["left.norm.fa"] , normalization_dir / selector ["right.norm.fa"], o )
      in
      (s, norm_fasta_sample_to_normalization_dir normalization_dir fasta_sample )
    )


let trinity_assemblies_of_norm_fasta norm_fasta {trinity_samples} memory threads =
  List.concat [
    List.filter_map norm_fasta ~f:(fun (s, norm_fasta) ->
        match (s.run_trinity, s.given_assembly) with
        | (true,false) -> Some (s, Trinity.trinity_fasta ~descr:(s.id ^ "_" ^ s.species) ~no_normalization:true ~full_cleanup:true ~memory ~threads norm_fasta)
        | (_, _)   -> None
      );
    List.filter_map trinity_samples ~f:(fun s ->
        if s.given_assembly then
          Some (s, input s.path_assembly)
        else
          None
      )
  ]

let transdecoder_orfs_of_trinity_assemblies trinity_assemblies { memory ; threads } =
  List.map trinity_assemblies ~f:(fun (s,trinity_assembly) ->
      match (s.run_transdecoder,s.given_assembly) with
      | (true,false) -> let pep_min_length = 50 in
        let retain_long_orfs = 150 in
        (s, (Transdecoder.transdecoder ~descr:("Assembly." ^ s.id ^ "_" ^ s.species) ~retain_long_orfs ~pep_min_length ~only_best_orf:false ~memory ~threads trinity_assembly))
      | (false, _ ) ->  (s, trinity_assembly)
      | (true, true) -> (s, trinity_assembly)
    )


let assemblies_stats_of_fasta =
  List.filter_map  ~f:(fun (s,assembly) ->
  if s.given_assembly then
    None
  else
    Some (s, Trinity.assembly_stats ~descr:(s.id ^ "_" ^ s.species) assembly)
  )


let concat ?(descr="") = function
  | [] -> raise (Invalid_argument "fastX concat: empty list")
  | x :: [] -> x
  | fXs ->
    workflow ~descr:("concat" ^ descr) [
      cmd "cat" ~stdout:dest [ list dep ~sep:" " fXs ]
    ]


let is_in ?(descr="") ~string_to_test ~file =
    workflow ~descr:(string_to_test ^".is_in" ^ descr) [
      cmd "grep" ~stdout:dest [ string "-x";
                                string string_to_test;
                                dep file];
    ]

let check_used_families ~used_fam_list ~usable_fam_file =
  let sorted_usable_fam_file = tmp // "usablefam.sorted.txt" in
  let sorted_all_used_fam_file = dest in
  let common_fam_file = tmp // "common_fam.txt" in
  let fam_subset_not_ok = tmp // "fam_subset_not_ok.txt" in
  let all_used_fam = Bistro.Template.(
      List.map used_fam_list ~f:(fun fam -> seq [string fam.name])
      |> seq ~sep:"\n"
      )
      in

  let script_post ~fam_subset_not_ok =
  let args = [
    "FILE_EMPTY", fam_subset_not_ok ;
  ]
  in
  bash_script args {|
    if [ -s $FILE_EMPTY ]
    then
      echo "These families are not in the \"Usable\" families:"
      cat $FILE_EMPTY
      echo "Use the option --just-parse-input and --family-subset with an empty file to get the file UsableFamilies.txt"
      exit 3
    else
      exit 0
    fi
    |}
  in
  workflow  ~descr:("check_used_families") [
    mkdir_p tmp;
    cmd "sort" ~stdout:sorted_usable_fam_file [ dep usable_fam_file;];
    cmd "sort" ~stdout:sorted_all_used_fam_file [ file_dump all_used_fam; ];
    cmd "join" ~stdout: common_fam_file [ string "-1 1"; sorted_all_used_fam_file; sorted_usable_fam_file];
    cmd "comm" ~stdout: fam_subset_not_ok [string "-3"; common_fam_file;sorted_all_used_fam_file];
    cmd "bash" [ file_dump (script_post ~fam_subset_not_ok)]
    ]



(*
Fasta file and its index must be in the same directory due to biopython
wich retains the relative path between these 2 files.
A different location is incompatible with the bistro docker usage
workflow by worflow.
To avoid to cp the complete fasta file we use a symbolic link.
*)
let build_biopythonindex ?(descr="") (fasta:fasta workflow)  : index workflow =
  workflow ~version:1 ~descr:("build_biopythonindex_fasta.py" ^ descr) [
    mkdir_p dest ;
    docker env (
      and_list [
        cmd "ln" [ string "-s" ; dep fasta ; dest // "seq.fa" ] ;
        cmd "build_biopythonindex_fasta.py" ~env [ dest // "index" ; dest // "seq.fa" ]
      ]
    )
  ]

let reformat_cdhit_cluster ?(descr="") cluster : fasta workflow =
  workflow ~version:1 ~descr:("reformat_cdhit_cluster2fasta.py" ^ descr) [
    cmd "reformat_cdhit_cluster2fasta.py" ~env [ dep cluster  ; ident dest]
  ]

let cdhitoverlap ?(descr="") ?p ?m ?d (fasta:fasta workflow) : cdhit directory workflow =
  let out = dest // "cluster_rep.fa" in
  workflow ~version:1 ~descr:("cdhitlap" ^ descr) [
    mkdir_p dest;
    cmd "cd-hit-lap" ~env [
        opt "-i" dep fasta;
        opt "-o" ident out ;
        option ( opt "-p" float ) p;
        option ( opt "-m" float ) m;
        option ( opt "-d" float ) d;
        ]
    ]

let blast_dbs_of_norm_fasta norm_fasta =
  List.filter_map norm_fasta ~f:(fun (s, norm_fasta) ->
      if s.run_apytram then
        let descr = (":" ^ s.id ^ "_" ^ s.species) in
        let fasta_to_norm_fasta_sample = function
          | Fasta_Single_end (w, _ ) -> w
          | Fasta_Paired_end (lw, rw , _) -> concat ~descr:(":" ^ s.id ^ ".fasta_lr") [ lw ; rw ]
        in
        let concat_fasta = fasta_to_norm_fasta_sample norm_fasta in
        (*Build biopython index*)
        let index_concat_fasta = build_biopythonindex ~descr concat_fasta in
        (*build overlapping read cluster*)
        let cluster_repo = cdhitoverlap ~descr concat_fasta in
        let rep_cluster_fasta = cluster_repo / selector  ["cluster_rep.fa"] in
        let cluster = cluster_repo / selector  ["cluster_rep.fa.clstr"] in
        (*reformat cluster*)
        let reformated_cluster = reformat_cdhit_cluster ~descr cluster in
        (*build index for cluster*)
        let index_cluster = build_biopythonindex ~descr reformated_cluster in
        (*Build blast db of cluster representatives*)
        let parse_seqids = true in
        let hash_index = true in
        let dbtype = "nucl" in
        let cluster_rep_blast_db = BlastPlus.makeblastdb ~hash_index ~parse_seqids ~dbtype  (s.id ^ "_" ^ s.species) rep_cluster_fasta in
        Some (s , {s; concat_fasta; index_concat_fasta; rep_cluster_fasta; reformated_cluster; index_cluster ; cluster_rep_blast_db} )
      else
        None
    )

let seq_dispatcher
    ?s2s_tab_by_family
    ~ref_db
    ~query
    ~query_species
    ~query_id
    ~ref_transcriptome
    ~threads
    ~seq2fam : fasta workflow =
  workflow ~np:threads ~version:9 ~descr:("SeqDispatcher.py:" ^ query_id ^ "_" ^ query_species) [
    mkdir_p tmp;
    cmd "SeqDispatcher.py" ~env [
      option (flag string "--sp2seq_tab_out_by_family" ) s2s_tab_by_family;
      opt "-d" ident (seq ~sep:"," (List.map ref_db ~f:(fun blast_db -> seq [dep blast_db ; string "/db"]) ));
      opt "-tmp" ident tmp ;
      opt "-log" seq [ dest ; string ("/SeqDispatcher." ^ query_id ^ "." ^ query_species ^ ".log" )] ;
      opt "-q" dep query ;
      opt "-qs" string query_species ;
      opt "-qid" string query_id ;
      opt "-threads" ident np ;
      opt "-t" dep ref_transcriptome ;
      opt "-t2f" dep seq2fam;
      opt "-out" seq [ dest ; string ("/Trinity." ^ query_id ^ "." ^ query_species )] ;
    ]
  ]

let trinity_annotated_fams_of_trinity_assemblies configuration_dir ref_blast_dbs threads=
  List.map ~f:(fun (s,trinity_assembly) ->
      let ref_db = List.map s.ref_species ~f:(fun r -> List.Assoc.find_exn ~equal:( = ) ref_blast_dbs r) in
      let query = trinity_assembly in
      let query_species= s.species in
      let query_id = s.id in
      let descr_ref = ":" ^(String.concat ~sep:"_" s.ref_species) in
      let ref_transcriptome = concat ~descr:(descr_ref ^ ".ref_transcriptome") (List.map s.ref_species ~f:(fun r -> (configuration_dir / ref_transcriptomes r))) in
      let seq2fam = concat ~descr:(descr_ref ^ ".seq2fam") (List.map s.ref_species ~f:(fun r -> (configuration_dir / ref_seq_fam_links r))) in
      let r =
        seq_dispatcher
          ~s2s_tab_by_family:true
          ~query
          ~query_species
          ~query_id
          ~ref_transcriptome
          ~seq2fam
          ~ref_db
          ~threads
      in
      (s, r)
    )


let concat_without_error ?(descr="") l : fasta workflow =
  let script =
    let vars = [
      "FILE", seq ~sep:"" l ;
      "DEST", dest ;
    ]
    in
    bash_script vars {|
        touch tmp
        cat tmp $FILE > tmp1
        mv tmp1 $DEST
        |}
    in
    workflow ~descr:("concat_without_error" ^ descr) [
       mkdir_p tmp;
       cd tmp;
       cmd "sh" [ file_dump script];
    ]

let build_target_query ref_species family configuration trinity_annotated_fams apytram_group =
    let seq_dispatcher_results_dirs =
        List.filter_map configuration.apytram_samples ~f:(fun s ->
            if (s.apytram_group = apytram_group) && (s.ref_species = ref_species) && (s.run_trinity) then
                Some (s , List.Assoc.find_exn ~equal:( = ) trinity_annotated_fams s)
            else
                None
            )
    in
    let get_trinity_annotated_fam_list =
    List.concat (List.map seq_dispatcher_results_dirs ~f:(fun (s,dir) ->
        [dep dir ; string ("/Trinity." ^ s.id ^ "." ^ s.species ^ "." ^ family ^ ".fa ")]
      )
    )
    in
    let descr = ":" ^ family ^ ".seqdispatcher" in
    concat_without_error ~descr get_trinity_annotated_fam_list


(*let apytram_orfs_ref_fams_of_apytram_annotated_ref_fams apytram_annotated_ref_fams memory =
  List.map apytram_annotated_ref_fams ~f:(fun (s, f, apytram_result_fasta) ->
      if s.run_transdecoder then
        let pep_min_length = 20 in
        let retain_long_orfs = 150 in
        let filtered_orf = Transdecoder.transdecoder ~descr:("Apytram." ^ s.id ^ "." ^ f) ~only_top_strand:true ~retain_long_orfs ~pep_min_length ~only_best_orf:true ~threads:1 ~memory apytram_result_fasta in
        (s, f, filtered_orf)
      else
        (s, f, apytram_result_fasta)
    )
*)

let checkfamily
  ?(descr="")
  ~ref_db
  ~(input:fasta workflow)
  ~family
  ~ref_transcriptome
  ~seq2fam
  ~evalue
  : fasta workflow =
  let tmp_checkfamily = tmp // "tmp" in
  let dest_checkfamily = dest // "sequences.fa" in
  workflow ~version:8 ~descr:("CheckFamily.py" ^ descr) [
    mkdir_p tmp_checkfamily;
    cd tmp_checkfamily;
    cmd "CheckFamily.py" ~env [
      opt "-tmp" ident tmp_checkfamily ;
      opt "-i" dep input ;
      opt "-t" dep ref_transcriptome ;
      opt "-f" string family;
      opt "-t2f" dep seq2fam;
      opt "-o" ident dest_checkfamily;
      (*opt "-d" ident (seq ~sep:"," (List.map ref_db ~f:(fun blast_db -> seq [dep blast_db ; string "/db"]) ));*)
      opt "-d" ident (seq ~sep:"," (List.map ref_db ~f:(fun blast_db -> seq [dep blast_db ; string "/db"]) ));
      opt "-e" float evalue;
    ]
  ]
  / selector [ "sequences.fa" ]

let apytram_checked_families_of_orfs_ref_fams apytram_orfs_ref_fams configuration_dir ref_blast_dbs =
 List.map apytram_orfs_ref_fams ~f:(fun (fam, fws) ->
  let checked_fws = List.map fws ~f:(fun (s, f, apytram_orfs_fasta) ->
    let input = apytram_orfs_fasta in
    let descr_ref = ":" ^(String.concat ~sep:"_" s.ref_species) in
    let ref_transcriptome = concat ~descr:(descr_ref ^  ".ref_transcriptome") (List.map s.ref_species ~f:(fun r -> (configuration_dir / ref_transcriptomes r))) in
    let seq2fam = concat ~descr:(descr_ref ^ ".seq2fam") (List.map s.ref_species ~f:(fun r -> (configuration_dir / ref_seq_fam_links r))) in
    let ref_db = List.map s.ref_species ~f:(fun r -> List.Assoc.find_exn ~equal:( = ) ref_blast_dbs r) in
    let checked_families_fasta = checkfamily ~descr:(":"^s.id^"."^f.name) ~input ~family:f.name ~ref_transcriptome ~seq2fam ~ref_db ~evalue:1e-40 in
    (s, f, checked_families_fasta)
    ) in
  (fam, checked_fws)
  )

let parse_apytram_results apytram_annotated_ref_fams =
  List.map apytram_annotated_ref_fams ~f:(fun (fam, fws) ->
    let config = Bistro.Template.(
        List.map fws ~f:(fun (s, f, w) ->
            seq ~sep:"\t" [ string s.species ; string s.id ; string f.name ; int f.f_id ; dep w ]
            )
        |> seq ~sep:"\n"
        )
    in
    let fw = workflow ~version:4 ~descr:("Parse_apytram_results.py."^fam.name) ~np:1  [
        cmd "Parse_apytram_results.py" ~env [ file_dump config ; dest ]] in
  (fam, fw)
  )

let transform_species_list l = (seq ~sep:",") (List.map l ~f:(fun sp -> string sp))

let seq_integrator
    ?realign_ali
    ?resolve_polytomy
    ?species_to_refine_list
    ?no_merge
    ?merge_criterion
    ~family
    ~trinity_fam_results_dirs
    ~apytram_results_dir
    ~alignment_sp2seq
    alignment
  : _ directory workflow =

  let merge_criterion_string  = match merge_criterion with
    | Some Merge ->  None
    | Some Length -> Some "length"
    | Some Length_complete -> Some "length.complete"
    | None -> None
    in
  let get_trinity_file_list extension dirs =
    List.map  dirs ~f:(fun (s,dir) ->
        [ dep dir ; string ("/Trinity." ^ s.id ^ "." ^ s.species ^ "." ^ family ^ "." ^ extension) ; string ","]
      )
    |> List.concat
  in

  let get_apytram_file_list extension dir =
    [ dep dir ; string ("/apytram." ^ family ^ "." ^ extension) ; string ","]
  in

  let trinity_fasta_list  =  get_trinity_file_list "fa" trinity_fam_results_dirs in
  let trinity_sp2seq_list  =  get_trinity_file_list "sp2seq.txt" trinity_fam_results_dirs in

  let apytram_fasta  =  get_apytram_file_list "fa" apytram_results_dir in
  let apytram_sp2seq  =  get_apytram_file_list "sp2seq.txt" apytram_results_dir in

  let sp2seq = List.concat [[dep alignment_sp2seq ; string "," ] ; trinity_sp2seq_list ; apytram_sp2seq ]  in
  let fasta = List.concat [trinity_fasta_list; apytram_fasta]  in

  let tmp_merge = tmp // "tmp" in

  workflow ~version:12 ~descr:("SeqIntegrator.py:" ^ family) [
    mkdir_p tmp_merge ;
    cmd "SeqIntegrator.py" ~env [
      opt "-tmp" ident tmp_merge;
      opt "-log" seq [ tmp_merge ; string ("/SeqIntegrator." ^ family ^ ".log" )] ;
      opt "-ali" dep alignment ;
      opt "-fa" (seq ~sep:"") fasta;
      option (flag string "--realign_ali") realign_ali;
      option (opt "--merge_criterion" string) merge_criterion_string;
      option (flag string "--no_merge") no_merge;
      option (flag string "--resolve_polytomy") resolve_polytomy;
      opt "-sp2seq" (seq ~sep:"") sp2seq  ; (* list de sp2seq delimited by comas *)
      opt "-out" seq [ dest ; string "/" ; string family] ;
      option (opt "-sptorefine" transform_species_list) species_to_refine_list;
    ]
  ]


let seq_filter
    ?realign_ali
    ?resolve_polytomy
    ?species_to_refine_list
    ~filter_threshold
    ~family
    ~alignment
    ~tree
    ~sp2seq
    : _ directory workflow  =

  let tmp_merge = tmp // "tmp" in

  workflow ~version:8 ~descr:("SeqFilter.py:" ^ family) [
    mkdir_p tmp_merge ;
    cmd "SeqFilter.py" ~env [
      opt "-tmp" ident tmp_merge;
      opt "-log" seq [ tmp_merge ; string ("/SeqFilter." ^ family ^ ".log" )] ;
      opt "-ali" dep alignment ;
      opt "-t" dep tree;
      opt "--filter_threshold" float filter_threshold;
      option (flag string "--realign_ali") realign_ali;
      option (flag string "--resolve_polytomy") resolve_polytomy;
      opt "-sp2seq" dep sp2seq  ;
      opt "-out" seq [ dest ; string "/" ; string family] ;
      option (opt "-sptorefine" transform_species_list) species_to_refine_list;
    ]
  ]

let merged_families_of_families configuration configuration_dir trinity_annotated_fams apytram_annotated_fams =
  List.map configuration.used_families ~f:(fun family ->
      let trinity_fam_results_dirs=
        List.map configuration.trinity_samples ~f:(fun s ->
            (s , List.Assoc.find_exn ~equal:( = ) trinity_annotated_fams s)
          )
      in
      let apytram_results_dir =  List.Assoc.find_exn ~equal:( = ) apytram_annotated_fams family in
      let merge_criterion = configuration.merge_criterion in
      let alignment = input (configuration.alignments_dir ^ "/" ^ family.name ^ ".fa")  in
      let alignment_sp2seq = configuration_dir / ali_species2seq_links family.name in
      let species_to_refine_list = List.map configuration.all_ref_samples ~f:(fun s -> s.species) in
      let w = if (List.length species_to_refine_list) = 0 then
                        seq_integrator ~realign_ali:false ~resolve_polytomy:true ~no_merge:true ~family:family.name ~trinity_fam_results_dirs ~apytram_results_dir ~alignment_sp2seq ~merge_criterion alignment
                    else
                        seq_integrator ~realign_ali:false ~resolve_polytomy:true ~species_to_refine_list ~family:family.name ~trinity_fam_results_dirs ~apytram_results_dir ~alignment_sp2seq ~merge_criterion alignment
                    in
      let tree = w / selector [family.name ^ ".tree"] in
      let alignment = w / selector [family.name ^ ".fa"] in
      let sp2seq = w / selector [family.name ^ ".sp2seq.txt"] in

      let filter_threshold = configuration.ali_sister_threshold in
      let wf = match (filter_threshold, (List.length species_to_refine_list)) with
        | (f, l) when ((f > 0.) && (l > 0)) ->
                 Some (seq_filter ~realign_ali:true ~resolve_polytomy:true ~filter_threshold ~species_to_refine_list ~family:family.name ~tree ~alignment ~sp2seq)
        | (_, _) ->  None
        in
      (family, w, wf )
    )

let phyldog_by_fam_of_merged_families merged_families configuration =
  List.map  merged_families ~f:(fun (fam, merged_without_filter_family, merged_and_filtered_family) ->
    let merged_family = match merged_and_filtered_family with
        | Some w -> w
        | None -> merged_without_filter_family
    in

    let ali = merged_family / selector [ fam.name ^ ".fa" ] in
    let tree = merged_family / selector [ fam.name ^ ".tree" ] in
    let link = merged_family / selector [ fam.name ^ ".sp2seq.txt" ] in
    let sptreefile = input configuration.species_tree_file in
    let profileNJ_tree = (ProfileNJ.profileNJ ~descr:(":" ^ fam.name) ~sptreefile ~link ~tree) / selector [ fam.name ^ ".tree" ] in
    let threads = 1 in
    let memory = Pervasives.min 1 (Pervasives.(configuration.memory / configuration.threads)) in
    let topogene = configuration.refinetree in
    (fam, Phyldog.phyldog_by_fam ~family:fam.name ~descr:(":" ^ fam.name) ~max_gap:95.0 ~threads ~memory ~topogene ~timelimit:9999999 ~sptreefile ~link ~tree:profileNJ_tree ali, merged_family)
    )

let realign_merged_families merged_and_reconciled_families configuration =
  List.map  merged_and_reconciled_families ~f:(fun (fam, reconciled_w, merged_w) ->
    (*let ali = merged_w / selector [ fam ^ ".fa" ] in
    let treein = reconciled_w / selector [ "Gene_trees/" ^ fam ^ ".ReconciledTree" ] in
    let threads = 1 in*)
    (*let maffttreein_realigned_w = Aligner.mafft ~descr:(":" ^ fam) ~threads ~treein ~auto:false ali in*)
    (*let mafftnogaptreein_realigned_w = Aligner.mafft_from_nogap ~descr:(":" ^ fam) ~threads ~treein ~auto:false ali in*)

    (*let muscle_realigned_w = Aligner.muscle ~descr:(":" ^ fam) ~maxiters:1 ali in*)
    (*let muscletreein_realigned_w = Aligner.muscletreein ~descr:(":" ^ fam) ~treein ~maxiters:1 ali in*)
    (*let musclenogap_realigned_w = Aligner.musclenogap ~descr:(":" ^ fam) ~maxiters:1 ali in*)
    (*let musclenogaptreein_realigned_w = Aligner.musclenogaptreein ~descr:(":" ^ fam) ~treein  ~maxiters:1 ali in*)
    (fam, (*maffttreein_realigned_w*)reconciled_w, merged_w (*mafftnogaptreein_realigned_w, muscle_realigned_w, muscletreein_realigned_w , musclenogap_realigned_w, musclenogaptreein_realigned_w*))
    )

let merged_families_distributor merged_reconciled_and_realigned_families configuration=
  let extension_list_merged = [(".fa","out/MSA_out");(".tree","out/GeneTree_out");(".sp2seq.txt","no_out/Sp2Seq_link")] in
  let extension_list_filtered = [(".discarded.fa","out/FilterSummary_out");(".filter_summary.txt","out/FilterSummary_out")] in

  let extension_list_reconciled = [(".ReconciledTree","Gene_trees/","out/GeneTreeReconciled_out");
                                   (".events.txt", "Species_tree/", "out/DL_out");
                                   (".orthologs.txt", "Species_tree/", "out/Orthologs_out")] in
  (*let extension_list_realigned = [(".realign.fa","Realigned_fasta/")] in*)
  workflow ~descr:"build_output_directory" ~version:1 (List.concat [
    [mkdir_p tmp;

    mkdir_p (dest // "out" // "MSA_out");
    mkdir_p (dest // "out" // "GeneTree_out");
    mkdir_p (dest // "no_out" // "Sp2Seq_link");
    ]
    ;
    if configuration.ali_sister_threshold > 0. && (List.length configuration.all_ref_samples) > 0 then
        [mkdir_p (dest // "out" // "FilterSummary_out")]
    else
        []
    ;
    if configuration.run_reconciliation then
       [mkdir_p (dest // "out" // "GeneTreeReconciled_out");
       mkdir_p (dest // "out" // "DL_out");
       mkdir_p (dest // "out" // "Orthologs_out");
       ]
    else
        []
    ;
    if configuration.refineali && configuration.run_reconciliation then
      [mkdir_p (dest // "Realigned_fasta")]
    else
      []
    ;
    [
    let script = Bistro.Template.(
      List.map merged_reconciled_and_realigned_families ~f:(fun (f, (*maffttreein_realigned_w,*) reconciled_w, merged_w (*mafftnogaptreein_realigned_w, muscle_realigned_w, muscletreein_realigned_w, musclenogap_realigned_w, musclenogaptreein_realigned_w*)) ->
          List.concat[
              List.map extension_list_merged ~f:(fun (ext,dir) ->
                let input = merged_w / selector [ f.name ^ ext ] in
                let output = dest // dir // (f.name ^ ext)  in
                seq ~sep:" " [ string "cp"; dep input ; ident output ]
              )
              ;
              if (configuration.ali_sister_threshold > 0.) &&  ((List.length configuration.all_ref_samples) > 0) then
                List.map extension_list_filtered ~f:(fun (ext,dir) ->
                    let input = merged_w / selector [ f.name  ^ ext ] in
                    let output = dest // dir // (f.name  ^ ext)  in
                    seq ~sep:" " [ string "cp"; dep input ; ident output ]
                )
              else
                []
              ;
              if configuration.run_reconciliation then
                List.concat [
                  List.map extension_list_reconciled ~f:(fun (ext,dirin,dirout) ->
                    let input = reconciled_w / selector [ dirin ^ f.name  ^ ext ] in
                    let output = dest // dirout // (f.name  ^ ext)  in
                    seq ~sep:" " [ string "cp"; dep input ; ident output ]
                    )
                  ;
                  (*if configuration.refineali then
                  List.concat_map [
                                    (*(mafftnogaptreein_realigned_w,".mafft.nogap.treein");*)
                                    (maffttreein_realigned_w,".mafft.treein") ;
                                    (muscle_realigned_w,".muscle") ;
                                    (muscletreein_realigned_w,".muscle.treein") ;
                                    (*(musclenogap_realigned_w,".muscle.nogap") ;*)
                                    (*(musclenogaptreein_realigned_w,".muscle.nogap.treein");*)
                                    ] ~f:(fun (w, e) ->
                    List.map extension_list_realigned ~f:(fun (ext,dir) ->
                        let input = w in
                        let output = dest // dir // (f ^ e ^ ext)  in
                        seq ~sep:" " [ string "cp"; dep input ; ident output ]
                    )
                    )
                  else
                    []
                *)
                ]
              else
                  []
              ;
              ]

            |> seq ~sep:"\n"
          )
        |> seq ~sep:"\n"
      )
    in
    cmd "bash" [ file_dump script ]
    ];
  ])

let get_reconstructed_sequences merged_and_reconciled_families_dirs configuration =
  if (List.length configuration.all_ref_samples) > 0 then
    let species_to_refine_list = List.map configuration.all_ref_samples ~f:(fun s -> s.species) in
    Some (workflow ~descr:"GetReconstructedSequences.py" ~version:6 [
            mkdir_p dest;
            cmd "GetReconstructedSequences.py" ~env [
            dep merged_and_reconciled_families_dirs // "out/MSA_out";
            dep merged_and_reconciled_families_dirs // "no_out/Sp2Seq_link";
            seq ~sep:"," (List.map species_to_refine_list ~f:(fun sp -> string sp));
            ident dest
            ]
        ])
  else
    None

(*
option (flag string "--realign_ali") realign_ali;
option (opt "-sptorefine" transform_species_list) species_to_refine_list;
let transform_species_list l = (seq ~sep:",") (List.map l ~f:(fun sp -> string sp))
*)


let write_orthologs_relationships (merged_and_reconciled_families_dirs:'a workflow) configuration =
    let (ortho_dir,species_to_refine_list) = match configuration.run_reconciliation with
        | true -> (Some(merged_and_reconciled_families_dirs / selector ["out/Orthologs_out"]),
                   Some(List.map configuration.all_ref_samples ~f:(fun s -> s.species)))
        | false -> (None, None)
    in
    workflow ~descr:"ExtractOrthologs.py" ~version:7 [
            mkdir_p dest;
            cmd "ExtractOrthologs.py" ~env [
            ident dest;
            dep merged_and_reconciled_families_dirs // "no_out/Sp2Seq_link";
            option (opt "" dep) ortho_dir ;
            option (opt "" transform_species_list) species_to_refine_list ;
            ]
    ]


let build_final_plots orthologs_per_seq merged_reconciled_and_realigned_families_dirs configuration =
    let formated_target_species = match configuration.all_ref_samples with
        | [] -> None
        | _ -> Some (List.map configuration.all_ref_samples ~f:(fun s ->
        seq ~sep:":" [string s.species ; string s.id])
      )
    in
    let dloutprefix = dest // "D_count" in
    workflow ~descr:"final_plots.py" ~version:19 (List.concat [
        [mkdir_p dest;
        cmd "final_plots.py" ~env [
            opt "-i_ortho" dep orthologs_per_seq;
            opt "-i_filter" dep (merged_reconciled_and_realigned_families_dirs / selector ["out/"]);
            opt "-o" ident dest;
            option (opt "-t_sp" (seq ~sep:",")) formated_target_species;
        ];
        ];
        if configuration.run_reconciliation then
        [cmd "CountDL.py" ~env [
            opt "-o" ident dloutprefix;
            opt "-sp_tree" dep (input (configuration.species_tree_file));
            opt "-rec_trees_dir" dep (merged_reconciled_and_realigned_families_dirs / selector ["out/GeneTreeReconciled_out"])
            ];
        ]
        else
        []

    ])

(*

let output_of_phyldog phyldog merged_families families =
  workflow ~descr:"output_of_phyldog" ~version:1 [
    mkdir_p (dest // "Alignments");
    mkdir_p (dest // "Sp2Seq_link");
    mkdir_p (dest // "Gene_trees");
    let extension_list = [(".fa","Alignments");(".sp2seq.txt","Sp2Seq_link")] in
    let script = Bistro.Template.(
        seq ~sep:"\n" [
          List.map extension_list ~f:(fun (ext,dir) ->
              List.map  merged_families ~f:(fun (f, w) ->
                  let input = w / selector [ f ^ ext ] in
                  let output = dest // dir // (f ^ ext)  in
                  seq ~sep:" " [ string "ln -s"; dep input ; ident output ]
                )
              |> seq ~sep:"\n"
            )
          |> seq ~sep:"\n" ;
          let (ext,dir) = (".ReconciledTree","Gene_trees/") in
          List.map families ~f:(fun f ->
              let input = phyldog / selector [ dir ^ f ^ ext ] in
              let output = dest // dir // (f ^ ".tree")  in
              seq ~sep:" " [ string "ln -s"; dep input ; ident output ]
            )
          |> seq ~sep:"\n";
        ]
      )
    in
    cmd "bash" [ file_dump script ];
  ]

  *)

let precious_workflows ~configuration_dir ~norm_fasta ~trinity_assemblies ~trinity_orfs ~reads_blast_dbs ~trinity_annotated_fams ~apytram_checked_families  ~merged_families ~merged_and_reconciled_families ~merged_reconciled_and_realigned_families ~apytram_annotated_fams =
  let any x = Bistro.Any_workflow x in
  let unwrap_fasta_sample = function
    | (_, Fasta_Single_end (w, _ )) -> [ any w ]
    | (_, Fasta_Paired_end (lw, rw , _)) -> [ any lw ; any rw ]
  in
  let get_reads_blast_dbs_w x = [any x.concat_fasta; any x.index_concat_fasta; any x.rep_cluster_fasta; any x.reformated_cluster; any x.index_cluster ; any x.cluster_rep_blast_db ] in
  let get_last_on_three x = match x with
    | (_, _, y) -> y in
  let get_second_on_three x = match x with
    | (_, y, _) -> y in
  (*let get_second_on_four x = match x with
    | (_, y, _, _) -> y in*)
  let get_merged_families = function
    |(_, w1, Some w2) -> [any w1; any w2]
    |(_, w1, None) -> [any w1]
    in
  let get_merged_reconciled_and_realigned_families = function
    |(_ , w1, w2 (*w3, w4, w5, w6, w7, w8*)) -> [any w1; any w2; (*any w3; any w4; any w5; any w6; any w7; any w8*)]
    in
  let get_checked_families = function
    | (_, fws) -> List.map fws ~f:(get_last_on_three % any)
    in
  List.concat [
    [any configuration_dir];
    List.concat_map norm_fasta ~f:unwrap_fasta_sample ;
    List.map trinity_assemblies ~f:(snd % any) ;
    List.map trinity_orfs ~f:(snd % any);
    List.concat_map reads_blast_dbs ~f:(snd % get_reads_blast_dbs_w);
    List.map trinity_annotated_fams ~f:(snd % any);
    List.concat_map merged_families ~f:get_merged_families;
    List.map merged_and_reconciled_families ~f:(get_second_on_three % any);
    List.concat_map merged_reconciled_and_realigned_families ~f:get_merged_reconciled_and_realigned_families;
    List.concat_map apytram_checked_families ~f:get_checked_families;
    List.map apytram_annotated_fams ~f:(snd % any);
  ]

let build_term configuration =

  (*let allocation_apytram = 80 in
  let allocation_trinity = 100 - allocation_apytram in

  let (apytram_memory, trinity_memory, trinity_threads) =
    if (List.length configuration.apytram_samples > 0) && (List.length configuration.trinity_samples > 0) then
      (Pervasives.( max 1 (configuration.memory * allocation_apytram / 100) ), Pervasives.(max 1 (configuration.memory * allocation_trinity / 100) ), Pervasives.( max 1 (configuration.threads * allocation_trinity / 100 )))
    else
      (configuration.memory ,configuration.memory , configuration.threads )
    in
  *)

  let (divided_sample_memory, divided_sample_threads) =
     let nb_samples = List.length configuration.all_ref_samples in
     (Pervasives.( max 1 (configuration.memory / (max 1 nb_samples)) ), Pervasives.(max 1 (configuration.threads / (max 1 nb_samples)) ))
    in

 (* let () = printf "%i %i %i\n" configuration.memory configuration.threads (List.length configuration.all_ref_samples) in
  let () = printf "%i %i %i\n" apytram_memory trinity_memory trinity_threads in
 *)

  let divided_thread_memory = Pervasives.(max 1 (configuration.memory / configuration.threads)) in

  let configuration_dir = parse_input ~sample_sheet:(input configuration.sample_sheet)
                                                ~species_tree_file:(input configuration.species_tree_file)
                                                ~alignments_dir:(input configuration.alignments_dir)
                                                ~seq2sp_dir:(input configuration.seq2sp_dir)
                                                ~all_families:configuration.all_families
                                                ~memory:divided_sample_memory
                                                ~configuration in

  let checked_used_families_all_together = check_used_families ~used_fam_list:configuration.used_families  ~usable_fam_file:(configuration_dir / selector [ "UsableFamilies.txt"]) in

  let ref_blast_dbs = ref_blast_dbs_of_configuration_dir configuration configuration_dir in

  let fasta_reads = fastq_to_fasta_conversion configuration configuration_dir in

  let norm_fasta = normalize_fasta fasta_reads divided_sample_memory configuration.memory divided_sample_threads in

  let trinity_assemblies = trinity_assemblies_of_norm_fasta norm_fasta configuration divided_sample_memory divided_sample_threads in

  let trinity_orfs = transdecoder_orfs_of_trinity_assemblies trinity_assemblies configuration in

  let trinity_assemblies_stats = assemblies_stats_of_fasta trinity_assemblies in

  let trinity_orfs_stats = assemblies_stats_of_fasta trinity_orfs in

  let trinity_annotated_fams = trinity_annotated_fams_of_trinity_assemblies configuration_dir ref_blast_dbs divided_sample_threads trinity_orfs in

  let reads_blast_dbs = blast_dbs_of_norm_fasta norm_fasta in

 (* let apytram_annotated_ref_fams =
    let pairs = List.cartesian_product configuration.apytram_samples configuration.families in
    List.map pairs ~f:(fun (s, fam) ->
        let query = configuration_dir / ref_fams s.ref_species fam in
        let blast_db = List.Assoc.find_exn blast_dbs s in
        let db_type = sample_fastq_orientation s.sample_fastq in
        let w = Apytram.apytram ~no_best_file:true ~write_even_empty:true ~plot:false ~i:5 ~evalue:1e-5 ~memory:divided_memory ~query db_type blast_db in
        let apytram_filename = "apytram." ^ s.ref_species ^ "." ^ fam ^ ".fasta" in
        (s, fam, w / selector [ apytram_filename ] )
      )
  in

*)


  let apytram_annotated_ref_fams_by_fam_by_groups =
      List.map configuration.used_families ~f:(fun fam ->
          let fws = List.concat (
                    List.map configuration.apytram_group_list ~f:(fun apytram_group ->
                    let pairs = List.cartesian_product configuration.all_apytram_ref_species [fam] in
                    List.concat (
                      List.map pairs ~f:(fun (ref_species, fam) ->
                        let descr = ":" ^ fam.name ^ "." ^ (String.concat ~sep:"_" ref_species) ^ "." ^ (String.strip apytram_group) in
                        let guide_query = concat ~descr (List.map ref_species ~f:(fun sp -> configuration_dir / ref_fams sp fam.name)) in
                        let target_query = build_target_query ref_species fam.name configuration trinity_annotated_fams apytram_group in
                        let query = concat ~descr:(descr ^ ".+seqdispatcher") [guide_query; target_query] in
                        let compressed_reads_dbs = List.filter_map reads_blast_dbs ~f:(fun (s, db) -> if s.ref_species = ref_species then Some db else None) in
                        let time_max = 18000 * List.length compressed_reads_dbs in
                        let w = Apytram.apytram_multi_species ~descr ~time_max ~no_best_file:true ~write_even_empty:true ~plot:false ~i:5 ~evalue:1e-10 ~out_by_species:true ~memory:divided_thread_memory ~fam:fam.name ~query compressed_reads_dbs in
                        List.filter_map configuration.apytram_samples ~f:(fun s ->
                          if (s.ref_species = ref_species) && (s.apytram_group = apytram_group) then
                              let apytram_filename = "apytram." ^ fam.name ^ "." ^ s.id ^ ".fasta" in
                              Some (s, fam, w / selector [ apytram_filename ] )
                          else
                              None
                           )
                        )
                      )
                  )
                  ) in
        (fam, fws)
    )
  in

  (*remove transdecoder after apytram
  let apytram_orfs_ref_fams = apytram_orfs_ref_fams_of_apytram_annotated_ref_fams apytram_annotated_ref_fams_by_fam divided_thread_memory in *)

  let apytram_orfs_ref_fams = apytram_annotated_ref_fams_by_fam_by_groups in

  let apytram_checked_families = apytram_checked_families_of_orfs_ref_fams apytram_orfs_ref_fams configuration_dir ref_blast_dbs in

  let apytram_annotated_fams = parse_apytram_results apytram_checked_families in

  let merged_families = merged_families_of_families configuration configuration_dir trinity_annotated_fams apytram_annotated_fams in

  let merged_and_reconciled_families = phyldog_by_fam_of_merged_families merged_families configuration in

  let merged_reconciled_and_realigned_families = realign_merged_families merged_and_reconciled_families configuration in

  let merged_reconciled_and_realigned_families_dirs = merged_families_distributor merged_reconciled_and_realigned_families configuration in

  let reconstructed_sequences = get_reconstructed_sequences merged_reconciled_and_realigned_families_dirs configuration in

  let orthologs_per_seq = write_orthologs_relationships merged_reconciled_and_realigned_families_dirs configuration in

  let final_plots = build_final_plots orthologs_per_seq merged_reconciled_and_realigned_families_dirs configuration in


  let open Repo in

  let target_to_sample_fasta s d = function
    | Fasta_Single_end (w, _ ) -> [[ d ; s.id ^ "_" ^ s.species ^ ".fa" ] %> w ]
    | Fasta_Paired_end (lw, rw , _) -> [[ d ; s.id ^ "_" ^ s.species ^ ".left.fa" ] %> lw ; [ d ; s.id ^ "_" ^ s.species ^ ".right.fa" ] %> rw]
  in
  let repo = if configuration.just_parse_input || (List.length configuration.used_families) = 0 then
    List.concat [
      List.map ["FamilyMetadata.txt"; "SpeciesMetadata.txt"; "UsableFamilies.txt"; "DetectedFamilies.txt"] ~f:(fun f ->
      [ f ] %>  (configuration_dir / selector [ f ]));
      [["UsedFamilies.txt"] %> checked_used_families_all_together] ;
    ]
      else
    List.concat [
      List.map ["FamilyMetadata.txt"; "SpeciesMetadata.txt"; "UsableFamilies.txt"; "DetectedFamilies.txt"] ~f:(fun f ->
      [ f ] %>  (configuration_dir / selector [ f ]));
      [["UsedFamilies.txt"] %> checked_used_families_all_together] ;
      List.concat_map trinity_assemblies ~f:(fun (s,trinity_assembly) ->
        if s.given_assembly then
          []
        else
          [[ "draft_assemblies" ; "raw_assemblies" ; "Draft_assemblies." ^ s.id ^ "_" ^ s.species ^ ".fa" ] %> trinity_assembly]
       )
        ;
      List.concat_map trinity_orfs ~f:(fun (s,trinity_orf) ->
            if s.given_assembly then
              []
            else
              [[ "draft_assemblies" ; "cds" ; "Draft_assemblies.cds." ^ s.id ^ "_" ^ s.species ^ ".fa" ] %> trinity_orf]
          )
      ;
       [["assembly_results_by_fam" ] %> (merged_reconciled_and_realigned_families_dirs / selector ["out/"])]
      ;
      [["all_fam.seq2sp.tsv"] %> (orthologs_per_seq / selector ["all_fam.seq2sp.tsv"])]
      ;
      [["plots"] %> final_plots];

      List.concat [
      match reconstructed_sequences with
        (*| Some w -> [["assembly_results_only_seq"] %> (w / selector ["assemblies/"]); ["assembly_results_by_fam";"Sp2Seq_out"; "all_fam.seq2sp.tsv"] %> (w / selector ["all_fam.seq2sp.tsv"])]*)
        | Some w -> [["assembly_results_only_seq"] %> (w / selector ["assemblies/"])]
        | None -> []
      ]
      ;

      if configuration.run_reconciliation then
        [["all_fam.orthologs.tsv"] %> (orthologs_per_seq/ selector["all_fam.orthologs.tsv"])]
      else
        []
      ;

      if configuration.get_reads then
      List.concat [
        List.concat (List.map fasta_reads ~f:(fun (s,sample_fasta) -> target_to_sample_fasta s "rna_seq/raw_fasta" sample_fasta))
        ;
        List.concat (List.map norm_fasta ~f:(fun (s,norm_fasta) -> target_to_sample_fasta s "rna_seq/norm_fasta" norm_fasta))
        ;
        ]
      else
        []
      ;
      if configuration.debug then
      List.concat [
        List.map trinity_assemblies_stats ~f:(fun (s,trinity_assembly_stats) ->
            [ "debug" ; "trinity_assembly" ; "trinity_assemblies_stats" ; "Trinity_assemblies." ^ s.id ^ "_" ^ s.species ^ ".stats" ] %> trinity_assembly_stats
          )
        ;
        List.map trinity_orfs_stats ~f:(fun (s,trinity_orfs_stats) ->
            [ "debug" ; "trinity_assembly" ; "trinity_assemblies_stats" ; "Transdecoder_cds." ^ s.id ^ "_" ^ s.species ^ ".stats" ] %> trinity_orfs_stats
          )
        ;
        List.map trinity_annotated_fams ~f:(fun (s,trinity_annotated_fams) ->
            [ "debug" ; "trinity_blast_annotation" ; "trinity_annotated_fams" ; s.id ^ "_" ^ s.species ^ ".vs." ^ (String.concat ~sep:"_" s.ref_species) ] %> trinity_annotated_fams
          )
        ;
         List.map ref_blast_dbs ~f:(fun (ref_species, blast_db) ->
            [ "debug" ; "trinity_blast_annotation" ; "ref_blast_db" ; ref_species ] %> blast_db
          )
        ;
        List.map reads_blast_dbs ~f:(fun (s,blast_db) ->
            [ "debug" ; "rna_seq" ;"rep_cluster_blast_db" ; s.id ^ "_" ^ s.species ] %> blast_db.cluster_rep_blast_db
          )
        ;
        List.map apytram_annotated_ref_fams_by_fam_by_groups ~f:(fun (fam, fws) ->
            List.map fws ~f:(fun (s, fam, apytram_result) ->
            [ "debug" ; "apytram_assembly" ; "apytram_results_by_ref_by_group_by_fam" ; fam.name ; s.id ^ "_" ^ s.species ^ ".fa" ] %> apytram_result
            )
          ) |> List.concat
        ;
        List.map apytram_checked_families ~f:(fun (fam, fws) ->
            List.map fws ~f:(fun (s, fam, apytram_result) ->
            [ "debug" ; "apytram_assembly" ; "apytram_checked_families" ; fam.name ; s.id ^ "_" ^ s.species ^ ".fa"] %> apytram_result
            )
          ) |> List.concat
        ;
        List.map apytram_annotated_fams ~f:(fun (fam, fw) ->
        [["debug" ; "apytram_assembly" ;"apytram_annotated_sequences"; fam.name ] %> fw]
        ) |> List.concat
        ;
        List.concat (List.map merged_families ~f:(fun (fam, merged_family, merged_and_filtered_family) ->
            match (merged_family, merged_and_filtered_family) with
                | (w1, Some w2) ->  [ [ "debug" ; "merged_families" ; fam.name  ] %> w1; [ "debug" ; "merged_filtered_families" ; fam.name  ] %> w2 ]
                | (w1, None) -> [[ "debug" ; "merged_families" ; fam.name  ] %> w1]
            )
          )
          ;
      ]
      else
      []
      ;
    ]
  in

  if configuration.just_parse_input then
    let precious = [Bistro.Any_workflow configuration_dir] in
    let repo_app = Repo.to_term repo ~precious ~outdir:configuration.outdir in
    repo_app
  else
    let open Term in
    let precious = precious_workflows ~configuration_dir ~norm_fasta ~trinity_assemblies ~trinity_orfs ~reads_blast_dbs ~trinity_annotated_fams ~apytram_checked_families ~merged_families ~merged_and_reconciled_families ~merged_reconciled_and_realigned_families ~apytram_annotated_fams in
    let repo_term = Repo.to_term repo ~precious ~outdir:configuration.outdir in
    let report_term =
      let assoc_arg xs =
        List.map xs ~f:(fun (s, w) -> (s, pureW w))
        |> assoc
      in
      pure
        (fun trinity_assemblies_stats final_plots () ->
           Report.generate
             ~trinity_assemblies_stats
             ~final_plots
             (Filename.concat configuration.outdir "report_end.html"))
      $ assoc_arg trinity_assemblies_stats
      $ pureW final_plots
    in
    report_term $ repo_term
