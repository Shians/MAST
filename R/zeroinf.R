##' Run a zero-inflated regression
##'
##' Fits a hurdle model on zero-inflated continuous data in which the zero process
##' is modeled as a logistic regression
##' and (conditional on the the response being >0), the continuous process is Gaussian, ie, a linear regression.
##' @param formula model formula
##' @param data a data.frame, list or environment in which formula is evaluated
##' @param lm.fun a function that takes a formula and data the arguments family='binomial' and family='gaussian', eg, \code{glm} or \code{glmer}.
##' @param silent if TRUE suppress common errors from fitting continuous part
##' @param subset ignored
##' @param ... passed to lm.fun
##' @return list of class 'zlm' with "disc"rete part and "cont"inuous part 
##' @export
##' @importFrom stringr str_detect
zlm <- function(formula, data,lm.fun=glm,silent=TRUE, subset, ...){
  #if(!inherits(data, 'data.frame')) stop("'data' must be data.frame, not matrix or array")
  if(!missing(subset)) warning('subset ignored')
  if(!inherits(formula, 'formula')) stop("'formula' must be class 'formula'")

  ## lm initially just to get pull response vector
  ## Turn glmer grouping "|" into "+" to get correct model frame
  sanitize.formula <- as.formula(gsub('[|]', '+', deparse(formula)))
  ## Throw error on NA, because otherwise the next line will fail mysteriously
  init <- tryCatch(model.frame(sanitize.formula, data, na.action=na.fail), error=function(e) if(str_detect(as.character(e), 'missing')) stop('NAs in response or predictors not allowed; please remove before fitting') else stop(e) )
  
  data[,'pos'] <-   model.response(init)>0
  cont <- try(lm.fun(formula, data, subset=pos, family='gaussian', ...), silent=silent)
  if(inherits(cont, 'try-error')){
    if(!silent) warning('Some factors were not present among the positive part')
    cont <- lm(0~0)
  }                                     
  
  formula.split <- strsplit(deparse(formula), '~')[[1]]
  lhs <- formula.split[1]
  if(str_detect(lhs, '[()]')) stop("Left hand side of formula must be unadorned variable name from 'data'")
  lhs <- 'pos'
  rhs <- formula.split[2]
  disc.formula <- paste(lhs, '~', rhs)
  disc <- lm.fun(disc.formula, data, family='binomial', ...)
  
  out <- list(cont=cont, disc=disc)
  class(out) <- 'zlm'
  out
}

is.empty.fit <- function(fit) return(length(coef(fit))==0 || summary(fit)$df.residual==0)

summary.zlm <- function(out){
  summary(out$cont)
  summary(out$disc)
}

##' Likelihood ratio test for hurdle model
##'
##' Do LR test separately on continuous and discrete portions
##' Combine for testing hypothesis.matrix
##'
##' This just internally calls lht from package car on the discrete and continuous models.
##' It tests the provided hypothesis.matrix using a Chi-Squared 
##' @param model output from zlm
##' @param hypothesis.matrix argument passed to lht, or naming a variable to be dropped from the model
##' @param type Test using Wald test or Likelihood Ratio test
##' @param silent Silence common errors in testing
##' @return array containing the discrete, continuous and combined tests
##' @importFrom car linearHypothesis
##' @importFrom car lht
##' @export
test.zlm <- function(model, hypothesis.matrix, type='Wald', silent=TRUE){
    if(length(type)!= 1 || (type != 'Wald'&& type != 'LRT')) stop("'type' must equal 'Wald' or 'LRT'")
    if(type=='LRT'){
        if(length(hypothesis.matrix) != 1) stop("Currently only support testing single factors when 'type'='LRT' and length of 'hypothesis.matrix' > 1")
        if(!inherits(model$disc, 'lm')) stop('Currently only support type=LRT with glm fits')
    }
    
  mer.variant <- any('chisq' %in% eval(formals(getS3method('linearHypothesis', class(model$disc)))$test)) #don't ask
    ## Get names to agree from output of all the different variants
  chisq <- 'Chisq'
  pchisq <- 'Pr(>Chisq)'
  names.drop1.cont <- c('Df', 'scaled dev.', 'Pr(>Chi)')
  names.drop1.disc <- c('Df', 'LRT', 'Pr(>Chi)')
  rename.drop1.cont <- c('scaled dev.'='Chisq', 'Pr(>Chi)'='Pr(>Chisq)')
  rename.drop1.disc <- c('LRT'='Chisq', 'Pr(>Chi)'='Pr(>Chisq)')
  if(mer.variant) {
    chisq <- 'chisq'
    pchisq <- 'Pr(> Chisq)'
  }
  if(type=='Wald'){
  tt <- try({
    cont <- lht(model$cont, hypothesis.matrix, test=chisq, singular.ok=TRUE)
  }, silent=silent)
  disc <- lht(model$disc, hypothesis.matrix, test=chisq, singular.ok=TRUE)
} else if(type=='LRT'){
    tt <- try({
    if(summary(model$cont)$df.residual==0) stop('No degrees of freedom left') #otherwise drop1 throws an obscure error
    cont <- rename(
        cbind(Res.df=NA, drop1(model$cont, hypothesis.matrix, test='LRT')[, names.drop1.cont]),
        rename.drop1.cont)
}, silent=silent)
        disc <- rename(
        cbind(Res.df=NA, drop1(model$disc, hypothesis.matrix, test='LRT')[, names.drop1.disc]),
        rename.drop1.disc)
    } else{
 stop('ruhroh')
}

    
  if(inherits(tt, 'try-error') || !all(dim(cont) == dim(disc))){
    cont <- rep(0, length(as.matrix(disc)))
    dim(cont) <- dim(disc)
    dimnames(cont) <- dimnames(disc)
    cont[,pchisq] <- NA 
  }

  res <- abind(disc, cont, disc+cont, rev.along=0)
  dimnames(res)[[3]] <- c('disc', 'cont', 'hurdle')
  res[,pchisq,3] <- sapply(seq_len(nrow(disc)), function(i)
                                 pchisq(res[i,'Chisq',3], df=res[i, 'Df', 3], lower.tail=FALSE))
      dm <- dimnames(res)
      names(dm) <- c('', 'metric', 'test.type')
  if(mer.variant) {
    dm[[2]][dm[[2]]==pchisq] <- 'Pr(>Chisq)'
  }
      dimnames(res) <- dm
  res
}

##' zero-inflated regression for SingleCellAssay 
##'
##' Fits a hurdle model in \code{formula} (linear for et>0), logistic for et==0 vs et>0.
##' Conducts likelihood ratio tests using hypothesis.matrix.
##'
##' A \code{list} of \code{data.frame}s, is returned, with one \code{data.frame} per tested predictor.
##' Rows of each \code{data.frame} are genes, the columns give the value of the LR test and its P-value, and the sum of the T-statistics for each level of the factor (when the predictor is categorical).
##' @title zlm.SingleCellAssay
##' @param formula a formula with the measurement variable on the LHS and predictors present in cData on the RHS
##' @param sca SingleCellAssay object
##' @param lm.fun a function accepting lm-style arguments and a family argument
##' @param hypothesis.matrix names of coefficients to test in lht form
##' @param type 
##' @param hypo.fun a function taking a model as input and returning output suitable for hypothesis.matrix
##' @param keep.zlm should the model objects be kept
##' @param .parallel run fits using parallel processing.  must have doParallel
##' @param .drop see ldply
##' @param .inform see ldply
##' @param silent Silence common problems with fitting some genes
##' @param ... passed to lm.fun
##' @return either an array of tests (one per primer) or a list
##' @export
##' @importFrom car lht
##' @importFrom plyr laply
##' @importFrom plyr llply
##' @importFrom plyr dlply
zlm.SingleCellAssay <- function(formula, sca, lm.fun=glm, hypothesis.matrix, type='Wald', hypo.fun=NULL, keep.zlm=FALSE, .parallel=FALSE, .drop=TRUE, .inform=FALSE, silent=TRUE, ...){

  
    m <- SingleCellAssay:::melt(sca)

    if(.drop) m <- droplevels(m)

    fit.primerid <- function(melted.gene, ...){
            model <- zlm(formula, melted.gene, lm.fun, silent=silent, ...)
            if(!is.null(hypo.fun) && inherits(hypo.fun, 'function')){
              hypothesis.matrix <- hypo.fun(model)
            }
            test <- test.zlm(model, hypothesis.matrix, type=type, silent=silent)
            list(model=model, test=test)
    }
    
    test.models <- dlply(m, ~primerid, fit.primerid, .drop=.drop, .inform=.inform, ...)

    tests <- laply(test.models, function(x){
      x$test[2,-1,]
    }, .inform=.inform)

    if(keep.zlm){
      models <-  llply(test.models, '[[', 'model', .inform=.inform)
      return(list(tests=tests, models=models))
    }

    return(tests)
}