%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Stochastich DCG Compiler
% Author: Christian Theil Have <cth@itu.dk>
% 
% Compiles a DCG to a PRISM program which works as a stochastic
% version of the original DCG.
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

:- op(1200, xfx, ==>).
:- op(1200, xfx, @=>).

:- dynamic sdcg_user_option/2.
:- dynamic sdcg_start_definition/2.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% SDCG Options
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

sdcg_default_option(start_symbol, start).
sdcg_default_option(maxdepth, 0).
sdcg_default_option(parsetree, false).
sdcg_default_option(parsetree_include_difflists,false).
sdcg_default_option(prism_file, 'generated_sdcg.psm').
sdcg_default_option(prism_invoker, prismn). % Use prismn (with FOC/FAM as default)
sdcg_default_option(use_foc_cheat,false).
sdcg_default_option(debug,false).

sdcg_option(Opt, Val) :-
	(clause(sdcg_user_option(Opt,_),_) ->
		sdcg_user_option(Opt,Val)
		;
	 	sdcg_default_option(Opt,Val)
	).

% These two shortcuts may be used for boolean options
sdcg_option(Opt) :-
	sdcg_option(Opt,true).
sdcg_set_option(Opt) :-
	sdcg_set_option(Opt,true).
	
sdcg_set_option(Opt,Val) :-
	check_valid_option(Opt,Val),
	sdcg_unset_option(Opt), % Discard old value if present
	assert(sdcg_user_option(Opt,Val)).

% Unset a previously set option. Never unsets the default value.
sdcg_unset_option(Opt) :-
	retractall(sdcg_user_option(Opt,_)).
	
sdcg_boolean_option(X) :-
	sdcg_default_option(X,false).
	
sdcg_positive_integer_option(X) :-
	sdcg_default_option(X,Y),
	integer(Y).

check_valid_option(Opt,Val) :-
	(check_option_name(Opt) ->
		(check_option_value(Opt,Val) ; throw(invalid_option_value(Opt,Val)))
		;
		throw(invalid_option(Opt))
	).

check_option_name(Opt) :-
	ground(Opt),
	sdcg_default_option(Opt,_). % There must a default option with this name

check_option_value(Opt,Val) :-
	ground(Val),
	(
		(sdcg_boolean_option(Opt), member(Val,[true,false]))
		;
		(sdcg_positive_integer_option(Opt), integer(V), V > 0)
		;
		atom(Val)
	).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Clause translation
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%-->(LHS,RHS) :- ==>(LHS,RHS).

% FIXME: ==> is probably a bad syntax choice (e.g. CHR)
==>(LHS,RHS) :-
	sdcg_debug((write('Processing rule '), write(LHS), write(' ==> '), write(RHS), nl)),
	expand_expanders(LHS,RHS,DerivedRules),
	process_expanded_rules(DerivedRules).

process_expanded_rules([]).
process_expanded_rules([Rule|Rest]) :-
	call(Rule),
	process_expanded_rules(Rest).

% @=> rules are considered expanded. Any special instructions are treated as normal constituents
@=>(LHS,RHS) :-
	sdcg_debug((write('Processing rule '), write(LHS), write(' @=> '), write(RHS), nl)),
	clause_to_list(RHS,RHSL),
	regex_expansions(RHSL,NewRHSL,ExpandedRules),
	sdcg_option(start_symbol,StartSymbol),
	(functor(LHS,StartSymbol,_) ->
		rewrite_start_rule(LHS,NewRHSL)
	;
		rewrite_rule(LHS,NewRHSL)
	),
	process_expanded_rules(ExpandedRules).

rewrite_start_rule(LHS,RHS) :-
	% The symbol "StartSymbol" is the root of the tree and must be unique, so throw
	% an exception if this is not the case.
	sdcg_option(start_symbol,StartSymbol),
	(clause(values(sdcg_start_definition,Def),_) -> throw(error(sdcg_start_symbol_already_defined(Def))) ; true),
	% Add diference lists to LHS:
	LHS =.. [ StartSymbol | Features ],
	append(Features,[In,Out], WithDiffList),
	% Add parse tree feature if requested
	(sdcg_option(parsetree,true) ->	append(WithDiffList,[ParseTree],WithAll) ; WithAll = WithDiffList),
	NewLHS =.. [ StartSymbol | WithAll ],
	% Rewrite RHS:
	rewrite_rule_rhs(In,Out,0,RHS,ParseTree,NewRHS),
	StartRule =.. [ :-,  NewLHS, NewRHS ],
	% Create and assert rule and start definition definition rule:
	assert_once(StartRule),
	functor(NewLHS,_,Arity),
	assert_once(sdcg_start_definition(StartSymbol/Arity)).

rewrite_rule(LHS,RHS) :-
	% Do we have a conditioning??
	(functor(LHS,'|',_) ->
		LHS =.. [ '|', Head, ConditionsClause ],
		clause_to_list(ConditionsClause,Conditions)
		;
		Conditions = [],
		Head = LHS
	),
	write(Head),nl,
	Head =.. [ Name | Features],
	functor(Head,_,Arity),

	% Expand values(Rulename, ...) to include this new nonterminal and give it a unique new name:
	expand_msw(Name, Arity, Conditions, ImplRuleName),
	
	create_selector_rule(Name,Arity,Conditions,SelectorRule),
	expand_asserted_set(sdcg_selector_rules,SelectorRule),
	sdcg_debug((write('Selector Rule: '),nl, portray_clause(SelectorRule))),
	create_implementation_rule(ImplRuleName,Features,RHS,ImplRule),
	expand_asserted_set(sdcg_implementation_rules, ImplRule),
	sdcg_debug((write('Implementation Rule: '),nl, portray_clause(ImplRule))).

% Some options may lead to generation of extra features
% For instance, if the the maxdepth option or parsetree option
% is set then, we will need some extra features to represent this.
create_selector_rule(Name,Arity,Conditions,SelectorRule) :-
	unifiable_list(Arity,FeatureStub),
	((Conditions == []) -> 
		ConditionParams = []
	;
		% Resolve conditioning mode
		unifiable_list(Arity,ConditioningModeList),
		CondModeClause =.. [ Name | ConditioningModeList ],
		(conditioning_mode(CondModeClause) ; throw(error_condition_mode_not_defined_for(Name/Arity))),
		resolve_conditioning_params(ConditioningModeList,FeatureStub,ConditionParams)
	),
	
	MSW =.. [ Name, Arity | ConditionParams ],
	Switch =.. [ msw, MSW, SwitchVar ],
	append(FeatureStub,[_In,_Out], HeadParams),
	append(FeatureStub,[_In,_Out], BodyParams),
	%generate_selector(BodyParams,SwitchVar,Values,RHS2),
	Selector =.. [ sdcg_rule | [SwitchVar|BodyParams] ],
	RHS = (Switch,Selector),
	LHS =.. [ Name | HeadParams ],
	SelectorRule1 =.. [ :-, LHS, RHS ],
	% Add a depth check if the option require it:
	sdcg_option(maxdepth, MaxDepth),
	((MaxDepth == 0) ->
		SelectorRule = SelectorRule1
		;
		add_selector_depth_check(SelectorRule1,SelectorRule)
	).

resolve_conditioning_params([],[],[]).
resolve_conditioning_params([+|CMRest],[Param|ParamRest],[Param|CondParamRest]) :-
	resolve_conditioning_params(CMRest,ParamRest,CondParamRest).
resolve_conditioning_params([-|CMRest],[_|ParamRest],CondParamRest) :-
	resolve_conditioning_params(CMRest,ParamRest,CondParamRest).
	
% Generate the implementation rule, by adding difference-lists and other
% requested features. 
% Name(in) : The atom representing the name of the rule
% Features(in) : A list of the of features of the rule
% RHS(in) : A list containing the constituents of the rule
% ImplRule(out) : The rewritten implementation rule.
create_implementation_rule(Name, Features,RHS,ImplRule) :-
	append(Features,[In,Out],Features1),
	(sdcg_option(parsetree) -> 
		(sdcg_option(parsetree_include_difflists) -> Rule =.. [Name|Features1] ; Rule =.. [Name|Features]),
		append(Features1,[[Rule,Parsetree]],Features2)
	;
		Features2 = Features1
	),
	(sdcg_option(maxdepth,0) ->	Features3 = Features2 ; append(Features2,[Depth],Features3)),
	LHS =.. [ sdcg_rule | [ Name | Features3 ]],
	(RHS == [[]] ->
		% In the case of an empty rule, the Out list should be the same as the in list.
		OutIsIn =..[=,Out,In],
		ImplRuleRHSList1 = [OutIsIn],
		(sdcg_option(parsetree,true) ->	
			Parsetree = [],
			append(ImplRuleRHSList1,[Parsetree],ImplRuleRHSList2)
		;
		 	ImplRuleRHSList2 = ImplRuleRHSList1
		),
		list_to_clause(ImplRuleRHSList2,ImplRuleRHS)
	;
		% Otherwise, rewrite RHS constituents (add difference-lists, etc.)
		rewrite_rule_rhs(In,Out,Depth,RHS,Parsetree,ImplRuleRHS)
	),
	ImplRule =.. [ :-, LHS, ImplRuleRHS ].

% rewrite_rule_rhs goes through constituents of a rule and rewrites each of them.
% In,Out (in) : The in and out difference list
% Depth(in): A variable for the parse tree depth
% RHS(in) : A list of constituents
% Parsetree(out): Expression for generating the parse tree for this rule.
% Body : The rewritten constituents (as a clause, not a list).
rewrite_rule_rhs(In, Out,_,[],[],Body) :-
	Body =.. [ =, Out, In ].
rewrite_rule_rhs(In, Out, Depth, [R], [ParseTreeFeature], Body) :-
	((R == []) ->
		Body =.. [ =, Out, In ]
	;is_list(R) ->
		generate_consumes(In,Out,R,Body)
	;is_composed(R) ->
		write('composed rules encountered'), write(R),nl
	;is_code_block(R) ->
		write('code block encountered'), write(R),nl,
		R =.. [{},Body], In = Out
	;
		% Add difference lists:
		R =.. L,
		append(L,[In,Out],L1),
		% Only if the parse tree feature is set, we create parsetree feature:
		(sdcg_option(parsetree,true) ->
			unifiable_list(1,[ParseTreeFeature]),
			append(L1,[ParseTreeFeature],L2)
		;
			L2 = L1
		),
		% Only if the maxdepth option is set, we add the depth feature:
		(sdcg_option(maxdepth,0) -> 
			L3 = L2
		;
			append(L2,[Depth],L3)
		),
		% Create rule body:
		Body =.. L3
	).
rewrite_rule_rhs(In, Out,Depth, [R | RHS], [ParseTree|ParseTreesRest], Body) :-
	rewrite_rule_rhs(In,NextIn,Depth,[R],[ParseTree],Clause),!,
	rewrite_rule_rhs(NextIn,Out,Depth,RHS,ParseTreesRest,ClausesRest),
	Body = (Clause, (ClausesRest)).

% FIXME: I might move this to PRISM program generation instead
generate_consumes(In,Out,[T],Clause) :-
	Clause =.. [ consume, In, T, Out ].
	generate_consumes(In,Out,[T|R],Clauses) :-
	generate_consumes(In,NextIn,[T],C1),!,
	generate_consumes(NextIn,Out,R,CR),
	Clauses = (C1, (CR)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Dynamic addition of features to rules
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Simply add the feature to the argument list of the lhs expr
add_lhs_feature(LHS,NewLHS,Feature) :-
	LHS =.. [ Rulename | LHSArgs ],
	append(LHSArgs,[Feature],NewLHSArgs),
	NewLHS =.. [ Rulename, NewLHSArgs ].

add_rhs_feature([],[],_,_).
add_rhs_feature([Constituent|ConstRest],[NewConstituent|NewConstRest],Feature,Condition) :-
	Constituent =.. [ Functor | ArgList ],
	% If condition is something like : check/0 then check(Functor) will be called
	(call(Condition,Functor) ->
		append(ArgList,[Feature],NewArgList),
		NewConstituent =.. [ Functor | NewArgList ]
	;
		NewConstituent = Constituent
	),
	add_rhs_feature(ConstRest,NewConstRest,Feature,Condition).
	
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Depth check
% The depth check is used to assure that the depth of the 
% parse tree stays below a certain threshold. This is useful
% to eliminate infinite recursion which will cause PRISM to 
% to eat your all your memory.
% 
% The depth check is "tagged on" to the rules generated by the
% compiler. 
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

selector_rhs_depth_feature_condition(sdcg_rule).

impl_rule_depth_feature_condition(ConstituentFunctor) :-
	ConstituentFunctor \== {}, % Code block, skip
	ConstituentFunctor \== [], % List, skip
	ConstituentFunctor \== ','. % composed rule, skip

add_selector_depth_check(SelectorRule,ModifiedRule) :-
	SelectorRule =.. [ :-, LHS, RHS ],
	CheckAndIncDepth =.. [ incr_depth, Depth, NewDepth ],
	add_lhs_feature(LHS,NewLHS,Depth),
	clause_to_list(RHS,RHSList),
	add_rhs_feature(RHSList,FeatAddedRHS,NewDepth,selector_rhs_depth_feature_condition),
	append([CheckAndIncDepth],FeatAddedRHS,FinalRHS),
	list_to_clause(FinalRHS,NewRHS),
	ModifiedRule =.. [ :-, NewLHS, NewRHS ].
	
%add_impl_depth_feature(ImplRule,DepthAddedImplRule) :-
	
% Add a depth feature to the implementation rule
%add_impl_rule_depth_feature(ImplRule,ModifiedRule) :-
%	ImplRule =.. [ :-, LHS, RHS ],

% Create a rule which increments the depth parameter and checks
% if it exceeds the maxdepth option
create_incr_depth(Rule) :-
	Head =.. [ incr_depth, Depth, NewDepth ],
	sdcg_option(maxdepth,Max),
	Body = ((integer(Depth), (NewDepth is Depth+1, (NewDepth<Max)))),
	Rule =.. [ :-, Head, Body ].
	
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Feature expansion
% expands rules prefixed with @
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Use the ExpanderRule to generate all derived rules
expand_expanders(LHS,RHS,Rules) :-
	create_expansion_rule(LHS,RHS,ExpanderRule),
	assert(ExpanderRule),
	write('Expander rule:'),nl,portray_clause(ExpanderRule),nl,
	ExpanderRule =.. [ :-, Head, _ ],
	functor(Head,ExpanderName,_),
	ExpCall =.. [ ExpanderName, X ],
	setof(X,ExpCall,Rules),
	retract(ExpanderRule).

% Create a rule, the invocation of which results in combinations
% of grammar rules based on the expansions in the original rule
create_expansion_rule(LHS,RHS,ExpRule) :-
	% Extract LHS expanders:
	(functor(LHS,'|',2) -> % Do we have conditions? They might need expansion too.
		LHS =.. [ '|', Head, Conditions],
		condition_expansion(Conditions,CondExpanders,CondVars)
		;
		CondExpanders = [],
		CondVars = [],
		Head = LHS
	),
	lhs_expansion(Head,LHSExpanders,LHSVars),
	% Extract RHS expanders:
	clause_to_list(RHS,RHSList),
	rhs_expansion(RHSList,RHSExpanders,RHSVars),
	% Join expanders:
	double_append(LHSExpanders,RHSExpanders,CondExpanders,Expanders),
	%append(LHSExpanders,RHSExpanders,Expanders1),
	%append(Expanders1,CondExpanders,Expanders),
	
	% Create LHS rule creator:
	functor(Head,FuncLHS,_),
	append([FuncLHS],LHSVars,NewLHSNoCond),
	(functor(LHS,'|',2) -> % Do we have conditions?
		list_to_clause(CondVars,CondVarsClause),
		NewLHSNoCondClause =.. NewLHSNoCond,
		NewLHS = [ '|', NewLHSNoCondClause, CondVarsClause ]
		; % no
		NewLHS = NewLHSNoCond
	),
	LHSAssignRule =.. [ =.. , R_LHS, (NewLHS) ],
	% Create RHS rule creator:
	list_to_clause(RHSVars,RHSClauses),
	RHSAssignRule =.. [ =, R_RHS, RHSClauses ],
	RuleRule =.. [ @=>, R_LHS, R_RHS ],
	AssignRuleRule =.. [ =, R, RuleRule ],
	AssignRules = [ LHSAssignRule,RHSAssignRule,AssignRuleRule],
	% Put together expansion rule:
	append(Expanders,AssignRules,ExpRuleBodyList),
	list_to_clause(ExpRuleBodyList,ExpRuleBody),
	ExpRuleHead =.. [ expander, R ],
	ExpRule =.. [ :-, ExpRuleHead, ExpRuleBody ], !.
	
	
condition_expansion(Conditions,Expanders,Vars) :-
	clause_to_list(Conditions,ConditionList),
	expand_feature_list(ConditionList,Expanders,Vars).

% Expands the LHS of a grammar rule into a set of expansion clauses and unification variables
lhs_expansion(LHS,Expanders,Vars) :-
	LHS =.. [ _ | Features ],
	expand_feature_list(Features,Expanders,Vars).
	/*
	lhs_expansion(LHS,Expanders,Vars) :-
		(functor(LHS, '|',2) ->
			LHS =.. [ '|', Head, ConditionClause ],
			Head =.. [ _, HeadFeatures ],
			clause_to_list(ConditionClause,ConditionList),
			expand_feature_list(HeadFeatures,HeadExpanders,HeadVars),
			expand_feature_list(ConditionList,ConditionExpanders,ConditionVars),
			append(HeadExpanders,ConditionExpanders,Expanders),
			append(HeadVars,ConditionVars,Vars)
			;
			LHS =.. [ _ | Features ],
			expand_feature_list(Features,Expanders,Vars)
		).
		*/

% Expands the RHS of a grammar rule into a set of expansion clauses and unification variables
rhs_expansion(RHS,Expanders,Vars) :-
	expand_feature_list(RHS,Expanders,Vars).
	
% Expand all constituents which have a @prefix into a prolog clauses and unification variables
% Call expand_feature_list1, which does the actual work and then cleanup junk (empty entries, spurious lists).
expand_feature_list(Features,Expanders,Vars) :-
	expand_feature_list1(Features,Expanders1,Vars1),
	flatten_once(Vars1,Vars),
	remove_empty(Expanders1,Expanders).
expand_feature_list1([],[],[]).
expand_feature_list1([Feature|R],[Expander|ER],[FVars|VR]) :-
	expand_feature(Feature,Expander,FVars),
	expand_feature_list1(R,ER,VR).
	
% If given an expansion feature e.g. @blah(ground,Y,Z), the variable "Expander" will
% be set to "blah(ground,Y,Z)" and NewFeatures will be a list [Y,Z] containing the
% unification variables.
expand_feature(Feature, Expander, NewFeatures) :-
	((nonvar(Feature),functor(Feature,@,1)) ->
		Feature =.. [ @, Expander ],
		Expander =.. [ _ | Args ],
		(resolve_expand_mode(Expander, ModeList) ->
			arg_expand_list(Args,ModeList,NewFeatures)
			; % No expand mode directive, assume that all unground variables are part of the expansion:
			remove_ground(Args,NewFeatures)
		)
		; % This is not an expander, so just keep things the way the are:
		Expander = [],
		NewFeatures = [ Feature ]
	).

% Given a list of arguments and a ModeList arg_expand_list will
% create a new list of the those arguments where the the corresponding 
% entry in the mode list contains a '+'. If the modelist contains a minus then
% the element from arglist will not be included in the outlist.
arg_expand_list([],[],[]).
arg_expand_list([_|ArgRest], [-|ModeRest], ExpList) :-
	arg_expand_list(ArgRest,ModeRest,ExpList).
arg_expand_list([Arg|ArgRest], [+|ModeRest], [Arg|ExpList]) :-
	arg_expand_list(ArgRest,ModeRest,ExpList).

% The expander is a clause blah(X,Y,Z) and resolve_expand_mode attempts
% to find an expand_mode directive for the clause (for instance 
% expand_mode(blah(+,+,-)) and then it creates a ModeList [+,+,-]
resolve_expand_mode(Expander, ModeList) :-
	Expander =.. [ Head | Args ],
	length(Args,ArgLen),
	unifiable_list(ArgLen,ModeList),
	ModeExpanderArg =.. [ Head | ModeList ], !,
	catch(expand_mode(ModeExpanderArg), _, fail).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Constituent expansion
% This allows regular expression like operators prefixed
% to the constituents, eg. s(X) --> *a(X), ?b(X), +c(Y).
% ? : The constiuents can appear zero or one time.
% * : The constituent can appear zero or more times
% + : The constituent can appear one or more times
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Expand regex in the RHS of a rule, creating a new RHS and the rules
% needed to implement the regular expressions encountered.
regex_expansions(RHSL,NewRHSL,Rules) :-
%	clause_to_list(RHS,RHSL),
	regex_expand(RHSL,NewRHSL,AddedRules),
%	list_to_clause(NewRHSL,NewRHS),
	flatten(AddedRules,Rules).

% Expand a list of constituents which may contain regex prefixed constituents
% Any regex prefixed constituents will be replaced by "a call" to the regular
% expression rules which are created as a side effect.
regex_expand([],[],[]).
regex_expand([Constituent|CRest],[NewConstituent|NCRest],[AddRules|AddRulesRest]) :-
	expand_constituent(Constituent,NewConstituent,AddRules),
	regex_expand(CRest,NCRest,AddRulesRest).

% Expand a single constituent (which may have regex prefix) to the rules implementing 
% the regex and an updated constituent referring to the added regex implementation rules
expand_constituent(Constituent, NewConstituent, AddedRules) :-
	(match_regex_op(Constituent,Operator,RealConstituent) -> % Regular expression constituent
		regex_type(Operator,RegexType,RegexRules),
		generate_regex_rules(RegexType, RealConstituent,NewConstituent,RegexRules,AddedRules)
	; 
		% Normal RHS constituent
		NewConstituent = Constituent,
		AddedRules = []
	).

% Matches a constituent (C) including a regex prefix to the
% regex prefix operator (Op) and the constituent excluding the prefix (R)
% It will fail if the constituent has no regex prefix
match_regex_op(C,Op,R) :-
	regex_type(Op,_,_),
	C =.. [Op,R].

% maps between the regex symbols <=> their names/types and the rules needed to implement them
regex_type(?, maybe, [regex_rule_none, regex_rule_one]).
regex_type(+, plus, [regex_rule_one, regex_rule_kleene]).
regex_type(*, star, [regex_rule_none, regex_rule_one, regex_rule_kleene]).

% Generates all regular expressions rules needed to implement a given type of regex (RegexType)
% The generated rules are unique for the individual constituent and regex type
generate_regex_rules(_,_,_,[],[]).
generate_regex_rules(RegexType, Constituent, NewConstituent, [RuleName|Rest], [Rule|RulesRest]) :-
	(var(NewConstituent) -> regex_rule_head(RegexType,Constituent,NewConstituent); true),
	GeneratorRule =.. [ RuleName, Constituent, NewConstituent, Rule ],
	call(GeneratorRule),
	generate_regex_rules(RegexType,Constituent,NewConstituent, Rest, RulesRest).
	
% Creates a novel name for the created rules
regex_rule_head(RegexType, Constituent,NewConstituent) :-
	Constituent =.. [ Name | ParamList ],
	atom_append(sdcg_regex_,RegexType,N1),
	atom_append(N1,'_',N2),
	atom_append(N2,Name,NewName),
	NewConstituent =.. [ NewName | ParamList ].

% Creates a rule of one of the three types:
% none - which matches the empty sequence.
% one - which matches exactly one element
% kleene - implements the kleene star operation:
% 	matches a repeated sequence of the same symbol any number of times (including zero)
regex_rule_none(_, NewConstituent, Rule) :-
	Rule =.. [ @=>, NewConstituent, [] ].
regex_rule_one(Constituent, NewConstituent,Rule) :-
	Rule =.. [ @=>, NewConstituent, Constituent ].
regex_rule_kleene(_,NewConstituent,Rule) :-
	Body = (NewConstituent,NewConstituent),
	Rule =.. [ @=>, NewConstituent, Body].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Loading and compiling SDCG from file
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Load, parse and compile the grammar given in File
sdcg(File) :-
	atom(File),
	sdcg_parse(File),
	section('Load and compile stage'),
	%sdcg_debug(listing),
	sdcg_compile.
	
% Load a list of files
sdcg([]) :-
	sdcg_compile.
sdcg([File|FilesRest]) :-
	sdcg_parse(File),
	sdcg(FilesRest).

sdcg_parse(File) :-
	sdcg_debug((write('Loading SDCG in '), write(File), nl)),
	open(File, read, Stream),
	ground(Stream),
	read_rules(Stream, Rules),
	compile_rules(Rules),
	close(Stream).

% Create list of Rules found in Stream
read_rules(Stream, Rules) :-
	read(Stream, T),
	((T == end_of_file) ->
		Rules = []
	;
		read_rules(Stream,Rest),
		append([T],Rest,Rules)
	).

% Compile the rules
% If a rule matches a template for SDCG rules it will compiled by simply calling it
% Normal prolog rules are asserted. 
% Note, that Prolog rules, which are referrenced from the grammar (via @ expansion) must
% be declared before the rules using them.
compile_rules([]).
compile_rules([X|R]) :-
	functor(X,F,A),
	(member([F,A], [[==>,2],[@=>,2],[sdcg_set_option,_]]) ->
		call(X)
	;
		assert(X)
	),
	compile_rules(R).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Prism program generation:
% Generate a prism program from the asserted clauses
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

section(S) :-
	nl,write('%%%  '),write(S),write('  %%%'),nl.

sdcg_compile :-
	sdcg_debug((write('compiling SDCG to PRISM program'),nl)),
	sdcg_option(prism_file, OutFile),
	write_prism_program_to_file(OutFile),
	sdcg_debug(section('FOC compilation')),
	%sdcg_debug(fo_trace),
	sdcg_option(prism_invoker,PI),
	InvokePRISM =.. [ PI, OutFile ],
	call(InvokePRISM).

write_prism_program :-
	write_prism_program(user_output).
	
% Doesn't work:
simulate_write_prism_program :- 
	open_null_stream(S),
	write_prism_program(S).

write_prism_program_to_file(FileName) :-
	open(FileName,write,Stream),
	write_prism_program(Stream),
	close(Stream).

write_prism_program(Stream) :-
	current_output(PreviousStream),
	set_output(Stream),
	write_prism_directives,
	section('MSW declarations'), 
	listing(values/2),
	write_sdcg_start_rule,
	retractall(values(_,_)), % Remove all asserted values clauses
	section('Selector rules:'),
	sdcg_selector_rules(SelectorRules),
	sdcg_debug((write('selector rules:'), write(SelectorRules),nl)),
	write_rules(SelectorRules),
	retractall(sdcg_selector_rules(_)),
	section('Implementation rules:'),
	sdcg_implementation_rules(ImplementationRules),
	sdcg_debug((write('implementation rules:'), write(ImplementationRules),nl)),
	write_rules(ImplementationRules),
	retractall(sdcg_implementation_rules(_)),
	section('Utilities:'),
	write_consume,
	(sdcg_option(use_foc_cheat) -> write_mysterious_all ; true),
	(not sdcg_option(maxdepth,0) -> write_incr_depth ; true),
	section('User defined'),
	listing,
	set_output(PreviousStream).

write_prism_directives :-
	% Make sure there is we have sdcg_start symbol
	(not(clause(sdcg_start_definition(_),_)) -> throw(error(no_sdcg_start_symbol)) ; true),
	sdcg_start_definition(Name/Arity),
	ground(Name),
	ground(Arity),
	section('PRISM directives'),
	writeq(target(failure,0)),dot,nl,
	NotSuccess =.. [ not, (success) ],
	Failure =.. [ :-, failure, NotSuccess ],
	portray_clause(Failure),
	ExceptOutArity is Arity - 1,
	unifiable_list(ExceptOutArity, L1),
	append(L1,[[]],L2),
	StartCall =.. [ Name | L2 ],
	Success =.. [ :-, success, StartCall ],
	portray_clause(Success),
	writeq(data(user)),dot, nl.

write_sdcg_start_rule :-
	section('Start symbol'),
	sdcg_start_definition(StartSymbol/Arity),
	listing(StartSymbol/Arity),
	unifiable_list(Arity,L),
	Head =.. [ StartSymbol | L],
	retractall(Head),
	retractall(sdcg_start_definition(_)).

write_rules([]).
write_rules([Rule|Rest]) :-
	portray_clause(Rule),
	write_rules(Rest).

remove_rule(N,Arity) :-
	unifiable_list(Arity,L),
	CL =.. [ N | L],
	(clause(CL,Body) -> retract((CL :- Body));
	throw(error(remove_rule(N/Arity))), write(CL), nl).
	
write_consume1 :-
	Head =.. [ consume, A, B, C],
	Body =.. [ =, A, [B|C] ],
	Clause =.. [ :-, Head, Body ],
	portray_clause(Clause).

write_consume :-
	write_append,
	Head =.. [ consume, A, B, C],
	Body =.. [ ap, [B], C, A ],
	Clause =.. [ :-, Head, Body ],
	portray_clause(Clause).
	
write_append :-
	Head1 =.. [ ap, [], A, B],
	Body1 =.. [ =, B, A ],
	Clause1 =.. [ :-, Head1, Body1 ],
	Head2 =.. [ ap, [H|X],Y,[H|Z] ],
	Body2 =.. [ ap, X,Y,Z],
	Clause2 =.. [ :-, Head2, Body2 ],
	portray_clause(Clause1),
	portray_clause(Clause2).
	
write_mysterious_all :-
	Head =.. [ all, [A], cont(A,B) ],
	Body =.. [ cont, A, B ],
	Clause =.. [ :-, Head, Body ],
	portray_clause(Clause).

write_incr_depth :-
	create_incr_depth(R),
	portray_clause(R).
	
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Utilities
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% The argument clause is only called if sdcg_option(debug,yes).
% Any write's from sdcg_debug goes to STDOUT, no matter current output stream
sdcg_debug(Clause) :-
	current_output(PreviousStream),
	set_output(user_output),
	(sdcg_option(debug,true) -> call(Clause)
	; true),
	set_output(PreviousStream).
	
expand_msw(Name,Arity,NewName) :-
	expand_msw(Name,Arity,[],NewName).
	
expand_msw(Name, Arity, Conditions,NewName) :-
	MSW =.. [Name,Arity|Conditions],
	% If the MSW is not defined yet we might get an error
	catch((values(MSW,Values);true), _,true),
		(ground(Values) ->
		% then extract largest id from the values
		Values = [ First | _ ], % New elements are always inserted in the beginning of the list
		peel_rightmost(First, _, Peeled),
		number_codes(LastId,Peeled),
		NextId is LastId + 1
		% Else: Just start with a new id
		; NextId = 1),
	replacement_name(Name, Arity, NextId, Conditions, NewName),
	update_msw(MSW, NewName).

update_msw(Name, Value) :-
	% Extract the values of L but if values is not defined yet (exception thrown)
	% then just assert it. 
	catch(	(values(Name,L) -> true; asssert(values(Name,[Value]))), _, assert(values(Name,[Value]))),
	(ground(L) -> true ; L = [Value]),		% Make sure L is grounded
	(member(Value,L) -> true ;
		retract(values(Name,_)),
		NewValues = [Value|L],
		assert(values(Name,NewValues))).

expand_asserted_set(Name, NewValue) :-
	Clause =.. [Name, Values],
	% The set clause might not have been asserted yet
	catch(Clause, _, Values = []),
	((Values == []) -> 
		NewClause =.. [ Name, [NewValue]]
	;
		retract(Clause),
		union([NewValue],Values,NewValues),
		NewClause =.. [ Name, NewValues ]
	),
	assert(NewClause).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Verification of the correctness of the generated program
verify :-
	prob(failure,F),
	prob(success,S),
	Total is S+F,
	write('Probability of succes: '),
	write(S),
	nl,
	write('Probability of failure: '),
	write(F),
	nl,
	write('In total (should be 1): '),
	write(Total),
	nl.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Test stuff
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

try_it :-
	(sdcg(X) ==> np(X)),
	(np(X) ==> det(X), noun(X)),
	(np(X) ==> noun(X)),
	(noun(sg) ==> [dog]),
	(noun(pl) ==> [dogs]),
	(det(pl) ==> [the]),
	(det(sg) ==> [the]),
	sdcg_compile.